# did:key and multikey parsing/formatting.
# Port of `packages/crypto/src/{did,utils}.ts`.

# Multicodec prefixes on public key bytes (varints)
const MULTICODEC_MULTIKEY = UInt64(0x1200)
const MULTICODEC_SECP256K1_PUB = UInt64(0xe7)

"Varint prefix for P-256 keys inside a multikey (0x80 0x24)."
const P256_DID_PREFIX = UInt8[0x80, 0x24]
"Varint prefix for secp256k1 keys inside a multikey (0xe7 0x01)."
const SECP256K1_DID_PREFIX = UInt8[0xe7, 0x01]

const BASE58_MULTIBASE_PREFIX = 'z'
const DID_KEY_PREFIX = "did:key:"

const JWT_ALG_TO_PREFIX = Dict{String,Vector{UInt8}}(
    "ES256" => P256_DID_PREFIX,
    "ES256K" => SECP256K1_DID_PREFIX,
)
const PREFIX_TO_JWT_ALG = Dict{Vector{UInt8},String}(
    P256_DID_PREFIX => "ES256",
    SECP256K1_DID_PREFIX => "ES256K",
)

_has_prefix(bytes::AbstractVector{UInt8}, prefix::AbstractVector{UInt8}) =
    length(bytes) >= length(prefix) && bytes[1:length(prefix)] == prefix

function _extract_multikey(did_key::AbstractString)::String
    startswith(did_key, DID_KEY_PREFIX) ||
        throw(InvalidMultikeyError("incorrect prefix for did:key: $did_key"))
    return SubString(did_key, nextind(did_key, 1, length(DID_KEY_PREFIX)):lastindex(did_key))
end

function _extract_prefixed_bytes(multikey::AbstractString)::Vector{UInt8}
    first(multikey) == BASE58_MULTIBASE_PREFIX ||
        throw(InvalidMultikeyError("incorrect prefix for multikey: $multikey"))
    payload = SubString(multikey, nextind(multikey, 1):lastindex(multikey))
    try
        return base58btc_decode(payload)
    catch err
        err isa ArgumentError || rethrow()
        throw(InvalidMultikeyError("invalid base58btc multikey: $(err.msg)"))
    end
end

"""
    parse_multikey(multikey) -> NamedTuple

Parse a multibase (base58btc, `z`-prefixed) multikey string into
`(jwt_alg = "ES256"|"ES256K", key_bytes = <uncompressed public key bytes>)`.
Public keys are decompressed to 65-byte uncompressed form, mirroring
`parseMultikey` in the TS reference.
"""
function parse_multikey(multikey::AbstractString)
    prefixed = _extract_prefixed_bytes(multikey)
    prefix = nothing
    for candidate in (P256_DID_PREFIX, SECP256K1_DID_PREFIX)
        if _has_prefix(prefixed, candidate)
            prefix = candidate
            break
        end
    end
    prefix === nothing && throw(UnsupportedKeyTypeError("unsupported key type"))
    alg = PREFIX_TO_JWT_ALG[prefix]
    compressed = prefixed[length(prefix)+1:end]
    key_bytes = decompress_pubkey(compressed; jwt_alg = alg)
    return (jwt_alg = alg, key_bytes = key_bytes)
end

"""
    format_multikey(jwt_alg, key_bytes) -> String

Format an uncompressed public key as a `z`-prefixed base58btc multikey
string. `jwt_alg` is `"ES256"` (P-256) or `"ES256K"` (secp256k1).
"""
function format_multikey(jwt_alg::AbstractString, key_bytes::AbstractVector{UInt8})::String
    prefix = get(JWT_ALG_TO_PREFIX, jwt_alg) do
        throw(UnsupportedKeyTypeError("unsupported key type: $jwt_alg"))
    end
    compressed = compress_pubkey(key_bytes; jwt_alg = jwt_alg)
    return "z" * base58btc_encode(vcat(prefix, compressed))
end

"""
    parse_did_key(did) -> NamedTuple

Parse a `did:key:z...` DID into `(jwt_alg, key_bytes)` where `key_bytes` is
the uncompressed public key. Throws [`InvalidMultikeyError`](@ref) /
[`UnsupportedKeyTypeError`](@ref) on bad input.
"""
parse_did_key(did::AbstractString) = parse_multikey(_extract_multikey(did))

"""
    format_did_key(jwt_alg, key_bytes) -> String

Format an uncompressed public key (P-256 or secp256k1) as a `did:key:z...`
string, exactly matching `formatDidKey` in the TS reference.
"""
format_did_key(jwt_alg::AbstractString, key_bytes::AbstractVector{UInt8})::String =
    DID_KEY_PREFIX * format_multikey(jwt_alg, key_bytes)
