# AT Protocol Service Auth JWT creation and verification.
# Spec: https://atproto.com/specs/xrpc#inter-service-authentication-jwt

"""
    ServiceAuthError <: ATProtoError

Exception thrown when verifying an AT Protocol inter-service authentication JWT fails.
"""
struct ServiceAuthError <: ATProtoError
    message::String
end

Base.showerror(io::IO, e::ServiceAuthError) = print(io, "ServiceAuthError: ", e.message)

"""
    ServiceAuthClaims

Verified payload claims from an AT Protocol inter-service authentication JWT.

# Fields
- `iss::DID`: Issuer DID (the user or service signing the request).
- `aud::String`: Audience DID (the target service DID, e.g. `"did:web:feed.example.com"`).
- `exp::Int`: Expiration Unix timestamp (seconds).
- `iat::Union{Int, Nothing}`: Issued-at Unix timestamp (seconds), if present.
- `lxm::Union{NSID, Nothing}`: Optional bound Lexicon XRPC method NSID.
- `jti::Union{String, Nothing}`: Optional unique token identifier (nonce).
"""
struct ServiceAuthClaims
    iss::DID
    aud::String
    exp::Int
    iat::Union{Int, Nothing}
    lxm::Union{NSID, Nothing}
    jti::Union{String, Nothing}
end

"""
    create_service_jwt(iss, aud, key::AbstractEcKey; lxm=nothing, exp=nothing, iat=nothing, jti=generate_nonce(16)) -> String

Create a signed AT Protocol inter-service authentication JWT (`ES256` or `ES256K`).

- `iss`: Issuer DID (`DID` or `AbstractString`).
- `aud`: Audience service DID (`DID` or `AbstractString`, e.g. `"did:web:api.example.com"`).
- `key`: Signing [`P256Key`](@ref) or [`Secp256k1Key`](@ref).
- `lxm`: Optional Lexicon method NSID binding this token to a single XRPC endpoint.
- `exp`: Expiration Unix timestamp in seconds (defaults to `iat + 60`).
- `iat`: Issued-at Unix timestamp in seconds (defaults to current Unix time).
- `jti`: Unique nonce string (defaults to 16 random bytes, hex/base64url encoded).
"""
function create_service_jwt(
    iss::Union{DID, AbstractString},
    aud::Union{DID, AbstractString},
    key::AbstractEcKey;
    lxm::Union{NSID, AbstractString, Nothing} = nothing,
    exp::Union{Integer, Nothing} = nothing,
    iat::Union{Integer, Nothing} = nothing,
    jti::Union{AbstractString, Nothing} = generate_nonce(16),
)::String
    iss_did = convert(DID, iss)
    aud_str = String(aud)
    now_i = isnothing(iat) ? Int(floor(time())) : Int(iat)
    exp_i = isnothing(exp) ? now_i + 60 : Int(exp)

    alg = jwt_alg(key)
    header = Dict{String, Any}("typ" => "JWT", "alg" => alg)
    payload = Dict{String, Any}(
        "iss" => String(iss_did),
        "aud" => aud_str,
        "iat" => now_i,
        "exp" => exp_i,
    )
    !isnothing(lxm) && (payload["lxm"] = String(convert(NSID, lxm)))
    !isnothing(jti) && (payload["jti"] = String(jti))

    return key isa P256Key ? sign_jwt_es256(key, header, payload) :
           sign_jwt_es256k(key, header, payload)
end

function _resolve_issuer_did_key(iss::DID, resolver::IdentityResolver)::String
    doc = resolve_did(resolver, iss)
    vm = signing_key(doc)
    isnothing(vm) && throw(ServiceAuthError("DID document for $iss has no #atproto signing key"))
    pk = vm.publicKeyMultibase
    if isnothing(pk) || isempty(pk)
        throw(ServiceAuthError("Verification method $(vm.id) missing publicKeyMultibase"))
    end
    return startswith(pk, "did:key:") ? pk : "did:key:" * pk
end

"""
    verify_service_jwt(token::AbstractString; aud=nothing, lxm=nothing, resolver=Identity._DEFAULT_RESOLVER, resolve_key=nothing, now_ts=floor(Int, time()), leeway=0) -> ServiceAuthClaims

Verify an AT Protocol inter-service authentication JWT and return its validated
[`ServiceAuthClaims`](@ref).

Checks:
1. Compact 3-part JWT structure and supported `alg` (`"ES256"` or `"ES256K"`).
2. Required claims (`iss` valid DID, `aud` string, `exp` integer).
3. Expiration (`now_ts <= exp + leeway`) and optional `aud` and `lxm` bindings.
4. Cryptographic signature verification against the issuer's DID signing key
   (resolved via `resolve_key(iss::DID) -> did_key::String` when provided, or via
   `resolver::IdentityResolver`).

Throws [`ServiceAuthError`](@ref) if any check fails.
"""
function verify_service_jwt(
    token::AbstractString;
    aud::Union{DID, AbstractString, Nothing} = nothing,
    lxm::Union{NSID, AbstractString, Nothing} = nothing,
    resolver::IdentityResolver = Identity._DEFAULT_RESOLVER,
    resolve_key = nothing,
    now_ts::Integer = Int(floor(time())),
    leeway::Integer = 0,
)::ServiceAuthClaims
    decoded = try
        jwt_decode(token)
    catch e
        throw(ServiceAuthError("Malformed JWT: $(sprint(showerror, e))"))
    end

    header = decoded.header
    payload = decoded.payload
    (header isa AbstractDict && payload isa AbstractDict) ||
        throw(ServiceAuthError("JWT header and payload must be JSON objects"))

    alg = get(header, "alg", nothing)
    (alg isa AbstractString && alg in ("ES256", "ES256K")) ||
        throw(ServiceAuthError("Unsupported JWT algorithm: $(repr(alg))"))

    iss_raw = get(payload, "iss", nothing)
    iss_raw isa AbstractString || throw(ServiceAuthError("JWT missing 'iss' claim"))
    iss_did = tryparse(DID, iss_raw)
    isnothing(iss_did) && throw(ServiceAuthError("Invalid issuer DID: $(repr(iss_raw))"))

    aud_raw = get(payload, "aud", nothing)
    (aud_raw isa AbstractString && !isempty(aud_raw)) ||
        throw(ServiceAuthError("JWT missing 'aud' claim"))
    aud_str = String(aud_raw)

    exp_raw = get(payload, "exp", nothing)
    (exp_raw isa Integer && !(exp_raw isa Bool)) ||
        throw(ServiceAuthError("JWT missing integer 'exp' claim"))
    exp_i = Int(exp_raw)

    if Int(now_ts) > exp_i + Int(leeway)
        throw(ServiceAuthError("Service auth JWT has expired (exp=$exp_i, now=$(Int(now_ts)))"))
    end

    if !isnothing(aud) && aud_str != String(aud)
        throw(ServiceAuthError("Audience mismatch: expected $(repr(String(aud))), got $(repr(aud_str))"))
    end

    iat_raw = get(payload, "iat", nothing)
    iat_i = (iat_raw isa Integer && !(iat_raw isa Bool)) ? Int(iat_raw) : nothing

    lxm_raw = get(payload, "lxm", nothing)
    lxm_nsid = if isnothing(lxm_raw)
        nothing
    elseif lxm_raw isa AbstractString
        parsed_lxm = tryparse(NSID, lxm_raw)
        isnothing(parsed_lxm) && throw(ServiceAuthError("Invalid 'lxm' NSID: $(repr(lxm_raw))"))
        parsed_lxm
    else
        throw(ServiceAuthError("Invalid 'lxm' claim type"))
    end

    if !isnothing(lxm)
        expected_lxm = convert(NSID, lxm)
        (isnothing(lxm_nsid) || lxm_nsid != expected_lxm) &&
            throw(ServiceAuthError("Lexicon method mismatch: expected $(expected_lxm), got $(repr(lxm_nsid))"))
    end

    jti_raw = get(payload, "jti", nothing)
    jti_str = jti_raw isa AbstractString ? String(jti_raw) : nothing

    key_str = try
        if isnothing(resolve_key)
            _resolve_issuer_did_key(iss_did, resolver)
        else
            String(resolve_key(iss_did))
        end
    catch e
        e isa ServiceAuthError && rethrow()
        throw(ServiceAuthError("Failed to resolve signing key for $iss_did: $(sprint(showerror, e))"))
    end

    parsed_key = try
        startswith(key_str, "did:key:") ? parse_did_key(key_str) : parse_multikey(key_str)
    catch e
        throw(ServiceAuthError("Invalid issuer signing key '$key_str': $(sprint(showerror, e))"))
    end

    parsed_key.jwt_alg == String(alg) ||
        throw(ServiceAuthError("JWT alg '$alg' does not match issuer key algorithm '$(parsed_key.jwt_alg)'"))

    sig_ok = if alg == "ES256"
        verify_jwt_es256(token, parsed_key.key_bytes)
    else
        verify_jwt_es256k(token, parsed_key.key_bytes)
    end
    sig_ok || throw(ServiceAuthError("Invalid JWT cryptographic signature"))

    return ServiceAuthClaims(iss_did, aud_str, exp_i, iat_i, lxm_nsid, jti_str)
end
