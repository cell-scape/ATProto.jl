# CAR (Content Addressable aRchives) v1/v2. Port of `packages/repo/src/car.ts`.
#
# CAR v1 layout:
#   varint-framed DAG-CBOR header {"roots": [CID...], "version": 1}
#   then, per block: varint(cid-bytes-len + data-len) ‖ cid-bytes ‖ data
#
# CAR v2 layout:
#   11-byte pragma (0x0a 0xa1 0x67 0x76 0x32 0x64 = CBOR {"v":2})
#   40-byte header: characteristics (16 bytes), data offset/len, index offset/len
#   inner CAR v1 payload, then (optional) index

const CAR_V2_PRAGMA = UInt8[0x0a, 0xa1, 0x67, 0x76, 0x32, 0x64]
const CAR_V2_HEADER_SIZE = 40

"Strip a CARv2 pragma+header if present; v1 bytes pass through."
function _car_payload(bytes::AbstractVector{UInt8})::Vector{UInt8}
    if length(bytes) >= 11 && bytes[1:length(CAR_V2_PRAGMA)] == CAR_V2_PRAGMA
        # v2 header: 16 bytes characteristics, u64 data-offset, u64 data-len,
        # u64 index-offset (all big-endian); data begins at 11 + data-offset
        # file layout (1-based): pragma bytes 1-11, header bytes 12-51;
        # header = characteristics(16) + data-offset u64 + data-len u64 + index u64
        data_offset = _be_u64(bytes, 28)
        data_len = _be_u64(bytes, 36)
        payload_start = 11 + CAR_V2_HEADER_SIZE + 1
        # data_offset counts from the end of the v2 header
        first = payload_start + Int(data_offset) - CAR_V2_HEADER_SIZE
        return bytes[first:(first + Int(data_len) - 1)]
    end
    return bytes
end

@inline function _be_u64(bytes, i)
    v = UInt64(0)
    for k in 0:7
        v = (v << 8) | bytes[i+k]
    end
    return v
end

function _read_varint(io::IOBuffer)::Int
    shift = 0
    value = UInt64(0)
    while true
        eof(io) && throw(ArgumentError("truncated varint in CAR"))
        b = read(io, UInt8)
        value |= UInt64(b & 0x7f) << shift
        (b & 0x80) == 0 && return Int(value)
        shift += 7
    end
end

function _write_varint(io::IOBuffer, n::Integer)
    v = UInt64(n)
    while true
        b = v & 0x7f
        v >>= 7
        if v == 0
            write(io, UInt8(b))
            return nothing
        end
        write(io, UInt8(b | 0x80))
    end
end

"""
    parse_car_cid(frame) -> (CID, consumed)

Parse a CID from the front of a block frame; `consumed` is the number of
bytes it occupies (v1: version + codec + multihash; v0: bare multihash).
"""
function parse_car_cid(frame::AbstractVector{UInt8})
    if length(frame) >= 2 && frame[1] == 0x12 && frame[2] == 0x20
        length(frame) >= 34 || throw(ArgumentError("truncated CIDv0 in CAR"))
        return (cid_from_bytes(frame[1:34]), 34)
    elseif !isempty(frame) && frame[1] == 0x01
        (codec, pos) = read_varint(frame, 2)
        (code, pos) = read_varint(frame, pos)
        pos <= length(frame) || throw(ArgumentError("truncated CID in CAR"))
        len = Int(frame[pos])
        total = pos + len  # pos was left at the length byte's index
        # length byte + digest
        total = (pos + 1) + len - 1
        total <= length(frame) || throw(ArgumentError("truncated CID in CAR"))
        return (cid_from_bytes(frame[1:total]), total)
    end
    throw(ArgumentError("invalid CID bytes in CAR frame"))
end

function read_varint(bytes::AbstractVector{UInt8}, pos::Int)::Tuple{UInt64,Int}
    shift = 0
    value = UInt64(0)
    while pos <= length(bytes)
        b = bytes[pos]
        pos += 1
        value |= UInt64(b & 0x7f) << shift
        (b & 0x80) == 0 && return (value, pos)
        shift += 7
    end
    throw(ArgumentError("truncated varint"))
end

"""
    read_car(bytes) -> (roots::Vector{CID}, blocks::BlockMap)

Read a CAR file (v1 or v2-prefixed). Returns header roots and all blocks.
"""
function read_car(bytes::AbstractVector{UInt8})
    data = _car_payload(bytes)
    io = IOBuffer(copy(data))
    header = dag_cbor_decode(_read_framed(io))
    get(header, "version", nothing) == 1 ||
        throw(ArgumentError("unsupported CAR version: $(get(header, "version", nothing))"))
    roots = CID[]
    for r in get(header, "roots", Any[])
        push!(roots, r isa CID ? r : cid_parse(String(r)))
    end
    blocks = BlockMap()
    for (cid, block_bytes) in CarReader(data)
        put_block!(blocks, cid, block_bytes)
    end
    return (roots = roots, blocks = blocks)
end

_read_framed(io::IOBuffer) = (len = _read_varint(io); read(io, len))

"""
    CarReader(data)

Lazy iterator over `(cid, bytes)` block pairs in a CAR v1 payload.
"""
struct CarReader
    bytes::Vector{UInt8}
end

function Base.iterate(reader::CarReader, state = nothing)
    if state === nothing
        io = IOBuffer(copy(reader.bytes))
        _read_framed(io)  # skip the header frame
        state = io
    end
    io = state
    eof(io) && return nothing
    frame_len = _read_varint(io)
    frame = read(io, frame_len)
    (cid, consumed) = parse_car_cid(frame)
    return ((cid, copy(frame[consumed+1:end])), io)
end

"""
    write_car(roots, blocks) -> Vector{UInt8}

Serialize roots + a `BlockMap` to CAR v1 bytes.
"""
function write_car(roots::AbstractVector{CID}, blocks::BlockMap)::Vector{UInt8}
    io = IOBuffer()
    header_bytes = dag_cbor_encode(Dict{String,Any}(
        "roots" => Any[r for r in roots], "version" => 1))
    _write_varint(io, length(header_bytes))
    write(io, header_bytes)
    for (cid, bytes) in blocks
        cid_raw = cid_bytes(cid)
        _write_varint(io, length(cid_raw) + length(bytes))
        write(io, cid_raw)
        write(io, bytes)
    end
    return take!(io)
end

"Write a CAR v2 (pragma + header wrapping the v1 payload, no index)."
function write_car_v2(roots::AbstractVector{CID}, blocks::BlockMap)::Vector{UInt8}
    v1 = write_car(roots, blocks)
    io = IOBuffer()
    write(io, CAR_V2_PRAGMA)
    write(io, zeros(UInt8, 11 - length(CAR_V2_PRAGMA)))  # pragma pads to 11 bytes
    write(io, zeros(UInt8, 16))                      # characteristics
    write(io, UInt8[0, 0, 0, 0, 0, 0, 0, CAR_V2_HEADER_SIZE])  # data offset = header size
    write(io, reinterpret(UInt8, [hton(UInt64(length(v1)))]))            # data length
    write(io, reinterpret(UInt8, [hton(UInt64(0))]))                     # index offset (none)
    write(io, v1)
    return take!(io)
end

"All blocks in a CAR file (convenience)."
car_blocks(bytes) = read_car(bytes).blocks
