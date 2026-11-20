# Digests and multihashes. Port of `packages/crypto/src/sha.ts` plus the
# multihash wrappers needed by CID.

"""
    sha256(data) -> Vector{UInt8}

SHA-256 digest of bytes (or of a UTF-8 encoded string). Uses the Julia SHA
stdlib, same values as the TS reference's `@noble/hashes` sha256.
"""
sha256(data::Union{AbstractVector{UInt8},Vector{UInt8}})::Vector{UInt8} = SHA.sha256(data)
sha256(data::AbstractString)::Vector{UInt8} = SHA.sha256(codeunits(data))

"""
    sha256hex(data) -> String

Lower-case hex SHA-256 digest of the input.
"""
sha256hex(data)::String = base16_encode(sha256(data))

# Multihash codes used in atproto
const MH_IDENTITY = UInt64(0x00)
const MH_SHA2_256 = UInt64(0x12)

"""
    sha256_multihash(data) -> Vector{UInt8}

Full multihash bytes for the SHA-256 of `data`:
`0x12 0x20 <32-byte digest>` (code 0x12, length 0x20).
"""
function sha256_multihash(data)::Vector{UInt8}
    digest = sha256(data)
    @assert length(digest) == 32
    return vcat(UInt8(0x12), UInt8(0x20), digest)
end

"""
    identity_multihash(data) -> Vector{UInt8}

Identity multihash (`0x00 <len> <data>`): the "hash" is the data itself.
Used for tiny inline CIDs.
"""
function identity_multihash(data::AbstractVector{UInt8})::Vector{UInt8}
    length(data) <= 127 ||
        throw(ArgumentError("identity multihash supports at most 127 bytes"))
    return vcat(UInt8(0x00), UInt8(length(data)), data)
end
identity_multihash(data::AbstractString) = identity_multihash(collect(codeunits(data)))

"""
    random_bytes(n::Int) -> Vector{UInt8}

`n` cryptographically-secure random bytes (OpenSSL RAND).
"""
random_bytes(n::Integer)::Vector{UInt8} = OpenSSL.random_bytes(Int(n))
