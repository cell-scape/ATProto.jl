# Canonical DAG-CBOR encoder (IPLD DAG-CBOR spec; RFC 7049 deterministic
# profile). Mirrors @ipld/dag-cbor from the TypeScript reference:
#
#   - definite lengths only (no indefinite/chunked encoding)
#   - only float64 (float16/float32 inputs are rejected)
#   - bignums (tags 2/3) are forbidden by the DAG-CBOR spec
#   - map keys: strings only, sorted length-first then bytewise
#     (RFC 7049 canonical ordering)
#   - CIDs: tag 42, byte string = 0x00 (identity multibase) ‖ CID bytes

# --- low-level writers ---------------------------------------------------------

@inline function _write_header!(io::IOBuffer, major::UInt8, arg::UInt64)
    if arg < 24
        write(io, UInt8(major << 5 | arg))
    elseif arg < 0x100
        write(io, UInt8(major << 5 | 24), UInt8(arg))
    elseif arg < 0x10000
        write(io, UInt8(major << 5 | 25), UInt8(arg >> 8), UInt8(arg & 0xff))
    elseif arg < 0x100000000
        b = reinterpret(UInt8, [hton(UInt32(arg))])
        write(io, UInt8(major << 5 | 26), b)
    else
        b = reinterpret(UInt8, [hton(UInt64(arg))])
        write(io, UInt8(major << 5 | 27), b)
    end
    return nothing
end

_write_bytes!(io::IOBuffer, bytes::AbstractVector{UInt8}) = (write(io, bytes); nothing)

# --- value encoders --------------------------------------------------------------

"""
    dag_cbor_encode(value) -> Vector{UInt8}

Encode a value into canonical DAG-CBOR bytes.

Accepted value types:
- `nothing` → null; `Bool` → true/false
- `Int64`/`UInt64` (and `Integer`s that fit; `BigInt` in native range only —
  bignum tags are forbidden by the DAG-CBOR spec)
- `Float64` only (rejects `Float16`/`Float32` to keep encodings canonical)
- `String`/`AbstractString` (UTF-8 text)
- [`DagBytes`](@ref) → byte strings
- [`CID`](@ref) → tag 42 links
- `AbstractVector` → arrays
- `AbstractDict` with `String` keys, or `NamedTuple` → maps (keys are
  re-sorted canonically)

Throws `ArgumentError` for anything else.
"""
function dag_cbor_encode(value)::Vector{UInt8}
    io = IOBuffer()
    _encode!(io, value)
    return take!(io)
end

_encode!(io::IOBuffer, ::Nothing) = (write(io, 0xf6); nothing)

_encode!(io::IOBuffer, b::Bool) = (write(io, b ? 0xf5 : 0xf4); nothing)

function _encode!(io::IOBuffer, n::Integer)
    _encode_int!(io, n)
    return nothing
end

function _encode_int!(io::IOBuffer, n::Integer)
    if n < 0
        # negative: major 1, argument is -1 - n (two's-complement wrap makes
        # this exact for typemin(Int64) as well)
        n >= typemin(Int64) || throw(ArgumentError(
            "integer out of DAG-CBOR native range (bignums are not allowed)"))
        _write_header!(io, 0x01, UInt64(-1 - Int64(n)))
    else
        n <= typemax(UInt64) || throw(ArgumentError(
            "integer out of DAG-CBOR native range (bignums are not allowed)"))
        _write_header!(io, 0x00, UInt64(n))
    end
    return nothing
end

function _encode!(io::IOBuffer, x::Float64)
    write(io, 0xfb, reinterpret(UInt8, [hton(UInt64(reinterpret(UInt64, x)))])...)
    return nothing
end

function _encode!(io::IOBuffer, x::Union{Float16,Float32})
    throw(ArgumentError(
        "DAG-CBOR only supports Float64 values; convert $(typeof(x)) to Float64 first"))
end

function _encode!(io::IOBuffer, s::AbstractString)
    str = String(s)
    _write_header!(io, 0x03, UInt64(ncodeunits(str)))
    write(io, codeunits(str))
    return nothing
end

function _encode!(io::IOBuffer, d::DagBytes)
    _write_header!(io, 0x02, UInt64(length(d.bytes)))
    _write_bytes!(io, d.bytes)
    return nothing
end

function _encode!(io::IOBuffer, c::CID)
    bytes = cid_bytes(c)
    _write_header!(io, 0x06, UInt64(42))            # tag 42
    _write_header!(io, 0x02, UInt64(length(bytes) + 1)) # bytes: 0x00 ‖ CID
    write(io, 0x00)
    _write_bytes!(io, bytes)
    return nothing
end

function _encode!(io::IOBuffer, a::AbstractVector)
    _write_header!(io, 0x04, UInt64(length(a)))
    for item in a
        _encode!(io, item)
    end
    return nothing
end

function _encode!(io::IOBuffer, m::AbstractDict)
    entries = Pair{String,Any}[]
    for (k, v) in m
        k isa AbstractString ||
            throw(ArgumentError("DAG-CBOR map keys must be strings, got $(typeof(k))"))
        push!(entries, String(k) => v)
    end
    _encode_map_entries!(io, entries)
    return nothing
end

function _encode!(io::IOBuffer, nt::NamedTuple)
    entries = Pair{String,Any}[String(k) => v for (k, v) in pairs(nt)]
    _encode_map_entries!(io, entries)
    return nothing
end

function _encode_map_entries!(io::IOBuffer, entries::Vector{Pair{String,Any}})
    sort!(entries; by = e -> _map_key_order(first(e)))
    _write_header!(io, 0x05, UInt64(length(entries)))
    for (k, v) in entries
        _write_header!(io, 0x03, UInt64(ncodeunits(k)))
        write(io, codeunits(k))
        _encode!(io, v)
    end
    return nothing
end

# RFC 7049 canonical map key ordering: shorter keys first, then bytewise.
# Tuple comparison over (codeunit length, UTF-8 bytes) is exactly this order.
_map_key_order(k::String) = (UInt64(ncodeunits(k)), codeunits(k))

function _encode!(io::IOBuffer, x)
    throw(ArgumentError("cannot DAG-CBOR encode value of type $(typeof(x))"))
end
