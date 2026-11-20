# Strict DAG-CBOR decoder. Mirrors @ipld/dag-cbor's strictness:
#
#   - definite lengths only; rejects indefinite-length items (0x1f)
#   - rejects float16 (0xf9) and float32 (0xfa); only float64 (0xfb)
#   - rejects unknown tags; only tag 42 (CID) is valid
#   - rejects bignum tags 2/3
#   - map keys must be strings, canonically sorted, with no duplicates
#   - exactly one top-level value; trailing bytes are an error
#   - text strings must be valid UTF-8
#   - tag-42 byte strings must carry the 0x00 identity-multibase prefix

struct _CborError <: Exception
    msg::String
end

Base.showerror(io::IO, e::_CborError) = print(io, "DAG-CBOR decode error: ", e.msg)

_err(msg::String) = throw(_CborError(msg))

"Read exactly one byte or error."
@inline function _read_byte(io::IOBuffer)::UInt8
    eof(io) && _err("unexpected end of data")
    return read(io, UInt8)
end

@inline function _read_be(io::IOBuffer, n::Int)::UInt64
    v = UInt64(0)
    for _ in 1:n
        v = (v << 8) | _read_byte(io)
    end
    return v
end

"""
    dag_cbor_decode(bytes) -> Any

Decode a single canonical DAG-CBOR value from `bytes`. Throws an error (a
`DAG-CBOR decode error`) on malformed, non-canonical, or trailing input.

Value mapping: integers → `Int64`/`UInt64`, floats → `Float64`, text →
`String`, byte strings → [`DagBytes`](@ref), booleans → `Bool`, null →
`nothing`, arrays → `Vector{Any}`, maps → `Dict{String,Any}`, links →
[`CID`](@ref).
"""
function dag_cbor_decode(bytes::AbstractVector{UInt8})
    io = IOBuffer(copy(bytes))
    value = _read_value!(io)
    eof(io) || _err("trailing data after value")
    return value
end

@inline function _read_value!(io::IOBuffer)
    ib = _read_byte(io)
    major = ib >> 5
    info = ib & 0x1f
    # major 7: simple values and floats are inline in the additional-info
    # bits; for floats the payload follows and must NOT be read as an argument
    major == 0x07 && return _read_simple!(io, info)
    arg = info < 24 ? UInt64(info) : _read_arg!(io, info)
    # Val-dispatch on the major type — Julia's native "pattern match"
    return _read_body!(io, Val(Int(major)), arg)
end

@inline function _read_arg!(io::IOBuffer, info::UInt8)::UInt64
    info == 0x18 && return _read_be(io, 1)
    info == 0x19 && return _read_be(io, 2)
    info == 0x1a && return _read_be(io, 4)
    info == 0x1b && return _read_be(io, 8)
    info == 0x1f && _err("indefinite-length items are not allowed")
    _err("reserved additional information value: $info")
end

# Major-type dispatch (RFC 7049): one method per major type.
_read_body!(io::IOBuffer, ::Val{0}, arg::UInt64) =
    arg <= typemax(Int64) ? Int64(arg) : arg  # uint64 beyond Int64 stays UInt64

function _read_body!(io::IOBuffer, ::Val{1}, arg::UInt64)
    arg <= 0x8000000000000000 ||  # 2^63: -1-arg stays within Int64
        _err("negative integer out of int64 range")
    return -1 - reinterpret(Int64, arg)  # safe: arg <= 2^63
end

_read_body!(io::IOBuffer, ::Val{2}, len::UInt64) = _read_dagbytes!(io, len)
_read_body!(io::IOBuffer, ::Val{3}, len::UInt64) = _read_text!(io, len)
_read_body!(io::IOBuffer, ::Val{4}, len::UInt64) = _read_array!(io, len)
_read_body!(io::IOBuffer, ::Val{5}, len::UInt64) = _read_map!(io, len)
_read_body!(io::IOBuffer, ::Val{6}, tag::UInt64) = _read_tag!(io, tag)
_read_body!(io::IOBuffer, ::Val{7}, arg::UInt64) = _read_simple!(io, UInt8(arg))

function _read_dagbytes!(io::IOBuffer, len::UInt64)::DagBytes
    len <= typemax(Int) || _err("byte string too large")
    buf = Base.Vector{UInt8}(undef, Int(len))
    bytes_read = readbytes!(io, buf)
    bytes_read == Int(len) || _err("unexpected end of data in byte string")
    return DagBytes(buf)
end

function _read_text!(io::IOBuffer, len::UInt64)::String
    len <= typemax(Int) || _err("text string too large")
    buf = Base.Vector{UInt8}(undef, Int(len))
    bytes_read = readbytes!(io, buf)
    bytes_read == Int(len) || _err("unexpected end of data in text string")
    isvalid(String, buf) || _err("invalid UTF-8 in text string")
    return String(buf)
end

function _read_array!(io::IOBuffer, len::UInt64)
    len <= typemax(Int) || _err("array too large")
    out = Base.Vector{Any}(undef, Int(len))
    for i in 1:Int(len)
        out[i] = _read_value!(io)
    end
    return out
end

function _read_map!(io::IOBuffer, len::UInt64)
    len <= typemax(Int) || _err("map too large")
    out = Dict{String,Any}()
    prev_key = nothing  # (len, bytes) order key of the previous map key
    for _ in 1:Int(len)
        # map keys must be text strings (major 3, definite)
        ib = _read_byte(io)
        (ib >> 5) == 0x03 || _err("map keys must be text strings")
        info = ib & 0x1f
        klen = info < 24 ? UInt64(info) : _read_arg!(io, info)
        key = _read_text!(io, klen)
        order = (UInt64(ncodeunits(key)), codeunits(key))
        if prev_key !== nothing
            _map_key_order_valid(prev_key::Tuple, order::Tuple) ||
                _err("map keys must be sorted length-first then bytewise (duplicate or out-of-order key \"$key\")")
        end
        prev_key = order
        value = _read_value!(io)
        out[key] = value  # duplicates already rejected via ordering check
    end
    return out
end

_map_key_order_valid(prev::Tuple, cur::Tuple) =
    prev[1] < cur[1] || (prev[1] == cur[1] && prev[2] < cur[2])

function _read_tag!(io::IOBuffer, tag::UInt64)
    tag == 42 || _err("unsupported tag $tag (only CID tag 42 is allowed)")
    d = _read_value!(io)
    d isa DagBytes || _err("tag 42 (CID) must contain a byte string")
    isempty(d.bytes) && _err("empty CID byte string")
    d.bytes[1] == 0x00 ||
        _err("CID byte string must start with 0x00 identity multibase prefix")
    try
        return cid_from_bytes(d.bytes[2:end])
    catch
        _err("invalid CID bytes in tag 42")
    end
end

function _read_simple!(io::IOBuffer, info::UInt8)
    if info == 0x14
        return false
    elseif info == 0x15
        return true
    elseif info == 0x16
        return nothing
    elseif info == 0x17
        _err("undefined values are not allowed")
    elseif info == 0x19
        _err("float16 values are not allowed (only float64)")
    elseif info == 0x1a
        _err("float32 values are not allowed (only float64)")
    elseif info == 0x1b
        bits = _read_be(io, 8)
        return reinterpret(Float64, bits)
    end
    _err("unsupported simple value or reserved additional-info: $info")
end
