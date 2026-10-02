# Unsigned LEB128 varints, as used by multicodec / multihash / CID.

"""
    varint_encode(u::Integer) -> Vector{UInt8}

Encode a non-negative integer as an unsigned LEB128 varint
(7 bits per byte, little-endian, continuation bit in the MSB).
"""
function varint_encode(u::Integer)::Vector{UInt8}
    u >= 0 || throw(ArgumentError("varint values must be non-negative"))
    out = UInt8[]
    v = UInt64(u)
    while true
        b = v & 0x7f
        v >>= 7
        if v == 0
            push!(out, UInt8(b))
            return out
        end
        push!(out, UInt8(b | 0x80))
    end
end

"""
    read_varint(bytes; pos=1) -> Tuple{UInt64, Int}

Decode an unsigned varint from `bytes` starting at byte index `pos`.
Returns `(value, next_position)`. Throws `ArgumentError` on truncated or
overlong input.
"""
function read_varint(bytes::AbstractVector{UInt8}; pos::Int = 1)::Tuple{UInt64,Int}
    value = UInt64(0)
    shift = 0
    i = pos
    while true
        i > length(bytes) && throw(ArgumentError("truncated varint"))
        b = bytes[i]
        i += 1
        value |= UInt64(b & 0x7f) << shift
        (b & 0x80) == 0 && return (value, i)
        shift += 7
        shift > 63 && throw(ArgumentError("varint too long (more than 10 bytes)"))
    end
end

"""
    varint_decode(bytes) -> UInt64

Decode a single unsigned varint occupying all of `bytes`. See
[`read_varint`](@ref) for positional decoding.
"""
function varint_decode(bytes::AbstractVector{UInt8})::UInt64
    (value, next) = read_varint(bytes)
    next == length(bytes) + 1 ||
        throw(ArgumentError("trailing bytes after varint"))
    return value
end
