# plc.directory client and operation verification.
# Server API: https://web.archive.org/web/20240401054255/https://plc.directory/ spec

"""
    PlcClient(; plc_url=DEFAULT_PLC_URL, timeout=3, fetch=default_fetch)

Read-only client for a plc.directory server: DID documents, operation
history, and audit logs. The transport is injectable (see
[`PlcResolver`](@ref)).
"""
struct PlcClient{F}
    plc_url::String
    timeout::Float64
    fetch::F
end

PlcClient(; plc_url::AbstractString = DEFAULT_PLC_URL, timeout::Real = 3.0,
          fetch::F = default_fetch) where {F} =
    PlcClient{F}(String(plc_url), Float64(timeout), fetch)

function _plc_get(client::PlcClient, path::AbstractString)
    url = client.plc_url * path
    res = client.fetch(url; headers = ["Accept" => "application/json"],
                       timeout = client.timeout)
    res.status == 404 && return nothing
    res.status == 200 || throw(ErrorException("plc directory error: HTTP $(res.status)"))
    return JSON.parse(String(copy(res.body)))
end

"Fetch a DID document (or `nothing` when unknown)."
get_document(client::PlcClient, did::AbstractString) =
    _plc_get(client, "/" * HTTP.URIs.escapeuri(did))

"Fetch the most recent (unsigned) operation for a DID."
get_last_operation(client::PlcClient, did::AbstractString) =
    _plc_get(client, "/" * HTTP.URIs.escapeuri(did) * "/log/last")

"Fetch the audit log (list of signed operations)."
get_audit_log(client::PlcClient, did::AbstractString) =
    _plc_get(client, "/" * HTTP.URIs.escapeuri(did) * "/log/audit")

"Fetch up to `count` operations after a given creation date (ISO datetime)."
function get_ops(client::PlcClient, did::AbstractString; count::Int = 100,
                 after::Union{AbstractString,Nothing} = nothing)
    after_query = after === nothing ? "" : "&after=" * HTTP.URIs.escapeuri(String(after))
    path::String = string("/", HTTP.URIs.escapeuri(String(did)), "/log?count=", count, after_query)
    return _plc_get(client, path)
end

# --- operation verification ------------------------------------------------------

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

"""
    plc_genesis_did(op) -> String

Derive the `did:plc` identifier from a `LegacyCreate` operation (as a Dict):
`did:plc:` + the first 24 chars of base32(ripemd160(sha256(dag-cbor(op)))).
"""
function plc_genesis_did(op::AbstractDict)::String
    unsigned = _unsigned_copy(op)
    bytes = dag_cbor_encode(unsigned)
    hash160 = ripemd160(sha256(bytes))
    # 15 bytes = exactly 24 base32 chars, no padding
    acc = UInt32(0)
    bits = 0
    out = Char[]
    for b in hash160
        acc = (acc << 8) | b
        bits += 8
        while bits >= 5
            bits -= 5
            push!(out, BASE32_ALPHABET[(Int(acc >> bits) & 31) + 1])
        end
    end
    bits > 0 && push!(out, BASE32_ALPHABET[(Int(acc << (5 - bits)) & 31) + 1])
    return "did:plc:" * String(out[1:24])
end

"Copy of the op without signature fields, for hashing."
function _unsigned_copy(op::AbstractDict)
    out = Dict{String,Any}()
    for (k, v) in op
        k == "sig" || k == "sigs" || (out[String(k)] = v)
    end
    return out
end

"""
    verify_legacy_create(op; expected_did=nothing) -> Bool

Verify a PLC `LegacyCreate` genesis operation (Dict with a recoverable
`sig`): the recovered secp256k1 key must be a `did:key` listed in
`rotationKeys`, and — when `expected_did` is given — the derived genesis DID
must match.
"""
function verify_legacy_create(op::AbstractDict;
                              expected_did::Union{AbstractString,Nothing} = nothing)::Bool
    get(op, "type", nothing) == "plc1" || return false
    haskey(op, "sig") || return false
    rotation_keys = get(op, "rotationKeys", nothing)
    rotation_keys isa AbstractVector || return false

    sig_bytes = try
        base64url_decode(String(op["sig"]))
    catch
        return false
    end
    length(sig_bytes) == 65 || return false

    digest = try
        sha256(dag_cbor_encode(_unsigned_copy(op)))
    catch
        return false
    end

    pubkey = try
        recover_pubkey(digest, sig_bytes)
    catch
        return false
    end
    recovered_did_key = format_did_key("ES256K", pubkey)
    any(String(k) == recovered_did_key for k in rotation_keys) || return false

    if expected_did !== nothing
        plc_genesis_did(op) == String(expected_did) || return false
    end
    return true
end

"""
    verify_operation(op, rotation_keys) -> Bool

Verify a PLC `Operation` or `Tombstone` (Dict with a `sigs` list): at least
one compact signature must be valid against one of the `rotation_keys`
(`did:key:z...` strings). The unsigned op is re-encoded canonically before
hashing, exactly as plc.directory does.
"""
function verify_operation(op::AbstractDict, rotation_keys::AbstractVector)::Bool
    sigs = get(op, "sigs", nothing)
    sigs isa AbstractVector || return false
    digest = try
        sha256(dag_cbor_encode(_unsigned_copy(op)))
    catch
        return false
    end
    for key_did in rotation_keys
        parsed = try
            parse_did_key(String(key_did))
        catch
            continue
        end
        for sig in sigs
            sig_bytes = try
                base64url_decode(String(sig))
            catch
                continue
            end
            length(sig_bytes) == 64 || continue
            verify_sig_digest(parsed.key_bytes, digest, sig_bytes;
                              jwt_alg = parsed.jwt_alg) && return true
        end
    end
    return false
end
