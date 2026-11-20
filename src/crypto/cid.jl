# IPLD Content Identifiers (CID). atproto uses CIDv0 (implicit dag-pb +
# sha2-256, base58btc "Qm...") and CIDv1 (dag-cbor + sha2-256, conventionally
# base32 "b...").

"Multicodec: dag-cbor (0x71). The codec used for all atproto repo blocks."
const DAG_CBOR_CODEC = UInt64(0x71)
"Multicodec: raw binary (0x55)."
const RAW_CODEC = UInt64(0x55)
"Multicodec: dag-pb / MerkleDAG protobuf (0x70). The CIDv0 implicit codec."
const DAG_PB_CODEC = UInt64(0x70)

const CODEC_NAMES = Dict{UInt64,String}(
    0x71 => "dag-cbor",
    0x55 => "raw",
    0x70 => "dag-pb",
    0x0129 => "dag-json",
    0x0201 => "json",
    0x0200 => "cbor",
    0x00 => "identity",
)

const NAME_TO_CODEC = Dict{String,UInt64}(v => k for (k, v) in CODEC_NAMES)

"""
    CID

An immutable, validated IPLD Content Identifier.

Fields:
- `version::UInt8` — `0` (implicit dag-pb) or `1`
- `codec::UInt64` — multicodec code (`DAG_CBOR_CODEC`, `RAW_CODEC`, …)
- `digest::Vector{UInt8}` — full multihash bytes (code + length + hash)

CIDs are equal when their codec and digest are equal (CIDv0 is equivalent to
a CIDv1 with the dag-pb codec and the same digest, matching multiformats
semantics).
"""
struct CID
    version::UInt8
    codec::UInt64
    digest::Vector{UInt8}

    function CID(version::Integer, codec::Integer, digest::AbstractVector{UInt8})
        version in (0, 1) || throw(InvalidCidError("CID version must be 0 or 1, got $version"))
        if version == 0
            codec == DAG_PB_CODEC || throw(InvalidCidError("CIDv0 must use the dag-pb codec"))
            _check_sha256_multihash(digest)
        else
            _check_multihash(digest)
        end
        return new(UInt8(version), UInt64(codec), copy(digest))
    end
end

function _check_sha256_multihash(digest::AbstractVector{UInt8})
    (length(digest) == 34 && digest[1] == 0x12 && digest[2] == 0x20) ||
        throw(InvalidCidError("CIDv0 requires a sha2-256 multihash (34 bytes)"))
    return digest
end

function _check_multihash(digest::AbstractVector{UInt8})
    # accept identity and sha2-256 multihashes only, like the TS reference
    (code, pos) = read_varint(digest)
    if code == MH_IDENTITY
        length(digest) >= pos + 1 || throw(InvalidCidError("truncated identity multihash"))
        len = Int(digest[pos])
        length(digest) == pos + len ||
            throw(InvalidCidError("identity multihash length mismatch"))
    elseif code == MH_SHA2_256
        _check_sha256_multihash(digest)
    else
        throw(InvalidCidError("unsupported multihash code: 0x$(base16_encode(varint_encode(code)))"))
    end
    return digest
end

"""
    cid_from_bytes(bytes) -> CID

Decode a CID from its binary form: `[0x12 0x20 <digest>]` for v0 or
`[0x01 <codec-varint> <multihash>]` for v1.
"""
function cid_from_bytes(bytes::AbstractVector{UInt8})::CID
    isempty(bytes) && throw(InvalidCidError("empty CID bytes"))
    if bytes[1] == 0x12
        # v0: the bytes ARE the sha2-256 multihash
        return CID(0, DAG_PB_CODEC, bytes)
    elseif bytes[1] == 0x01
        (codec, pos) = read_varint(bytes; pos = 2)
        return CID(1, codec, bytes[pos:end])
    end
    throw(InvalidCidError("invalid CID binary form (expected 0x12 or 0x01 prefix)"))
end

"""
    cid_parse(s) -> CID

Parse a CID string: a base58btc `Qm...` string (CIDv0) or a multibase-prefixed
CIDv1 (`b...` base32 by atproto convention; `z`, `u`, `f`, … also accepted).
"""
function cid_parse(s::AbstractString)::CID
    isempty(s) && throw(InvalidCidError("empty CID string"))
    try
        if startswith(s, "Qm")
            # CIDv0 must decode to a 46-char base58btc sha2-256 multihash
            bytes = base58btc_decode(s)
            return CID(0, DAG_PB_CODEC, bytes)
        end
        bytes = multibase_to_bytes(s)
        return cid_from_bytes(bytes)
    catch err
        if err isa ArgumentError || err isa ATProtoCryptoError
            # normalize codec/multibase/multihash failures to InvalidCidError
            msg = err isa ATProtoCryptoError ? err.msg : err.msg
            (err isa InvalidCidError || startswith(msg, "CID")) && rethrow()
            throw(InvalidCidError("invalid CID string: $msg"))
        end
        rethrow()
    end
end

"""
    cid_bytes(cid) -> Vector{UInt8}

Binary form of the CID: the multihash itself for v0; version + codec varint +
multihash for v1.
"""
function cid_bytes(cid::CID)::Vector{UInt8}
    cid.version == 0 && return copy(cid.digest)
    return vcat(UInt8(0x01), varint_encode(cid.codec), cid.digest)
end

"""
    Base.string(cid) -> String

Serialize: base58btc for v0 (`Qm...`), base32 (multibase `b` prefix) for v1 —
the atproto convention.
"""
function Base.string(cid::CID)::String
    cid.version == 0 && return base58btc_encode(cid.digest)
    return "b" * base32_encode(cid_bytes(cid))
end

"""
    cid_for_dagcbor(block_bytes) -> CID

The CIDv1 (dag-cbor, sha2-256) for a serialized block — the standard CID used
throughout atproto repositories.
"""
cid_for_dagcbor(block_bytes)::CID = CID(1, DAG_CBOR_CODEC, sha256_multihash(block_bytes))

"""
    cid_codec_name(codec) -> String

Human-readable multicodec name (e.g. `"dag-cbor"`), or `"codec-0x<hex>"` for
unknown codes.
"""
function cid_codec_name(codec::UInt64)::String
    return get(CODEC_NAMES, codec) do
        return "codec-0x" * string(codec; base = 16)
    end
end

Base.:(==)(a::CID, b::CID) = a.codec == b.codec && a.digest == b.digest
Base.hash(cid::CID, h::UInt) = hash(cid.digest, hash(cid.codec, h))
Base.isless(a::CID, b::CID) = cid_bytes(a) < cid_bytes(b)
Base.show(io::IO, cid::CID) = print(io, string(cid))
Base.print(io::IO, cid::CID) = print(io, string(cid))
