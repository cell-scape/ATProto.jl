#= syntax/recordkey.jl =#

"""
    RECORD_KEY_RX

Regular expression matching a valid AT Protocol record key (excluding `.` and `..` checks).
"""
const RECORD_KEY_RX = r"^[a-zA-Z0-9._~:-]{1,512}\z"

"""
    TID_RX

Regular expression matching a valid 13-character AT Protocol Timestamp Identifier (TID).
"""
const TID_RX = r"^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z"

const _TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz"

@inline _is_rkey_byte(b::UInt8) =
    _is_ascii_alnum(b) || b == UInt8('.') || b == UInt8('_') ||
    b == UInt8('~') || b == UInt8(':') || b == UInt8('-')

@inline _is_tid_first_byte(b::UInt8) =
    (UInt8('2') <= b <= UInt8('7')) || (UInt8('a') <= b <= UInt8('j'))

@inline _is_tid_byte(b::UInt8) =
    (UInt8('2') <= b <= UInt8('7')) || (UInt8('a') <= b <= UInt8('z'))

"""
    valid_record_key_char(c::AbstractChar) -> Bool

Return `true` if `c` is an allowed ASCII character in a record key (`[a-zA-Z0-9._~:-]`).
"""
valid_record_key_char(c::AbstractChar) =
    _is_ascii_alnum(c) || c == '.' || c == '_' || c == '~' || c == ':' || c == '-'

function _validate_record_key_bytes(cu, start::Int, stop::Int)
    n = stop - start + 1
    n <= 0 && return "Record key cannot be empty"
    n > 512 && return "Record key is too long (512 characters max)"
    @inbounds if (n == 1 && cu[start] == UInt8('.')) ||
                 (n == 2 && cu[start] == UInt8('.') && cu[start + 1] == UInt8('.'))
        return "Record key cannot be '.' or '..'"
    end

    @inbounds for i in start:stop
        _is_rkey_byte(cu[i]) ||
            return "Disallowed characters in record key (ASCII letters, digits, . _ ~ : - only)"
    end

    return nothing
end

_validate_record_key(rkey::Union{String, SubString{String}}) =
    _validate_record_key_bytes(codeunits(rkey), 1, ncodeunits(rkey))

_validate_record_key(rkey::AbstractString) = _validate_record_key(String(rkey))

"""
    is_valid_record_key(rkey::AbstractString) -> Bool

Return `true` if `rkey` satisfies the AT Protocol Record Key syntax specification.

# Examples
```jldoctest
julia> ATProto.Syntax.is_valid_record_key("self")
true

julia> ATProto.Syntax.is_valid_record_key("3jui7kd54zh2y")
true

julia> ATProto.Syntax.is_valid_record_key("..")
false
```
"""
is_valid_record_key(rkey::AbstractString) = isnothing(_validate_record_key(rkey))

"""
    ensure_valid_record_key(rkey::AbstractString) -> Nothing

Validate `rkey` against the AT Protocol Record Key specification, throwing a
[`SyntaxError`](@ref) if invalid.
"""
function ensure_valid_record_key(rkey::AbstractString)
    err = _validate_record_key(rkey)
    isnothing(err) || throw(SyntaxError(:record_key, String(rkey), err))
    return nothing
end

"""
    RecordKey(s::AbstractString)

Validated AT Protocol Record Key (1–512 characters from `[a-zA-Z0-9._~:-]`,
excluding `"."` and `".."`).

Can also be constructed with `parse(RecordKey, s)`, `tryparse(RecordKey, s)`,
or the compile-time string macro `rkey"self"`.
"""
struct RecordKey
    value::String
    RecordKey(::_Unchecked, value::String) = new(value)
    function RecordKey(s::AbstractString)
        ensure_valid_record_key(s)
        return new(String(s))
    end
end

function Base.tryparse(::Type{RecordKey}, s::AbstractString)
    is_valid_record_key(s) || return nothing
    return RecordKey(_Unchecked(), String(s))
end

Base.parse(::Type{RecordKey}, s::AbstractString) = RecordKey(s)
Base.convert(::Type{RecordKey}, s::AbstractString) = RecordKey(s)
Base.convert(::Type{RecordKey}, r::RecordKey) = r
Base.convert(::Type{String}, r::RecordKey) = r.value
Base.String(r::RecordKey) = r.value
Base.print(io::IO, r::RecordKey) = print(io, r.value)
Base.show(io::IO, r::RecordKey) = print(io, "RecordKey(", repr(r.value), ")")
Base.isless(a::RecordKey, b::RecordKey) = isless(a.value, b.value)

StructUtils.structlike(::Type{RecordKey}) = false
StructUtils.lower(r::RecordKey) = r.value
StructUtils.lift(::Type{RecordKey}, x::AbstractString) = RecordKey(x)

"""
    @rkey_str -> RecordKey

Compile-time validated AT Protocol record key literal, e.g. `rkey"self"`.
"""
macro rkey_str(s::String)
    return RecordKey(s)
end

# -----------------------------------------------------------------------------
# TID (Timestamp Identifier)
# -----------------------------------------------------------------------------

function _validate_tid(tid::Union{String, SubString{String}})
    ncodeunits(tid) == 13 || return "TID must be exactly 13 characters"
    cu = codeunits(tid)
    @inbounds begin
        _is_tid_first_byte(cu[1]) ||
            return "TID first character must be in [234567abcdefghij]"
        for i in 2:13
            _is_tid_byte(cu[i]) ||
                return "TID characters must be base32-sortable ([234567a-z])"
        end
    end
    return nothing
end

_validate_tid(tid::AbstractString) = _validate_tid(String(tid))

"""
    is_valid_tid(tid::AbstractString) -> Bool

Return `true` if `tid` is a valid 13-character base32-sortable AT Protocol TID.
"""
is_valid_tid(tid::AbstractString) = isnothing(_validate_tid(tid))

"""
    ensure_valid_tid(tid::AbstractString) -> Nothing

Validate `tid` against the AT Protocol TID specification, throwing [`SyntaxError`](@ref)
if invalid.
"""
function ensure_valid_tid(tid::AbstractString)
    err = _validate_tid(tid)
    isnothing(err) || throw(SyntaxError(:tid, String(tid), err))
    return nothing
end

"""
    TID(s::AbstractString)

Validated 13-character base32-sortable AT Protocol Timestamp Identifier (TID).

Encodes a 53-bit UTC microsecond timestamp and a 10-bit random clock identifier.
Supports lexicographical ordering via `isless` and generation via [`next_tid`](@ref).
"""
struct TID
    value::String
    TID(::_Unchecked, value::String) = new(value)
    function TID(s::AbstractString)
        ensure_valid_tid(s)
        return new(String(s))
    end
end

function _tid_decode_u64(s::String)
    cu = codeunits(s)
    val = UInt64(0)
    @inbounds for i in 1:13
        b = cu[i]
        d = b <= UInt8('7') ? (b - UInt8('2')) : (b - UInt8('a') + UInt8(6))
        val = (val << 5) | UInt64(d)
    end
    return val
end

function _tid_encode_u64(val::UInt64)
    buf = Vector{UInt8}(undef, 13)
    alph = codeunits(_TID_ALPHABET)
    v = val
    @inbounds for i in 13:-1:1
        buf[i] = alph[(v & UInt64(0x1f)) + 1]
        v >>= 5
    end
    return String(buf)
end

"""
    tid_timestamp_us(t::TID) -> Int64

Return the UTC timestamp encoded in `t`, in microseconds since the Unix epoch.
"""
tid_timestamp_us(t::TID) = Int64(_tid_decode_u64(t.value) >> 10)

"""
    tid_clockid(t::TID) -> Int

Return the 10-bit clock identifier encoded in `t` (`0:1023`).
"""
tid_clockid(t::TID) = Int(_tid_decode_u64(t.value) & UInt64(0x3ff))

const _TID_LOCK = ReentrantLock()
const _TID_LAST_US = Ref{UInt64}(0)
const _TID_CLOCKID = Ref{UInt64}(0)

"""
    next_tid(; clockid::Union{Integer, Nothing}=nothing) -> TID

Generate a new monotonically increasing [`TID`](@ref) based on the current UTC
wall clock (microsecond precision) and a 10-bit clock identifier.
"""
function next_tid(; clockid::Union{Integer, Nothing}=nothing)
    now_us = floor(UInt64, time() * 1_000_000)
    ts, cid = Base.@lock _TID_LOCK begin
        if _TID_CLOCKID[] == 0 && isnothing(clockid)
            _TID_CLOCKID[] = rand(UInt64(0):UInt64(1023))
        end
        t = max(now_us, _TID_LAST_US[] + UInt64(1))
        _TID_LAST_US[] = t
        c = isnothing(clockid) ? _TID_CLOCKID[] : (UInt64(clockid) & UInt64(0x3ff))
        (t, c)
    end
    # Ensure top bit is 0 (53-bit timestamp << 10 | 10-bit clockid)
    raw = ((ts & UInt64(0x001f_ffff_ffff_ffff)) << 10) | cid
    return TID(_Unchecked(), _tid_encode_u64(raw))
end

function Base.tryparse(::Type{TID}, s::AbstractString)
    is_valid_tid(s) || return nothing
    return TID(_Unchecked(), String(s))
end

Base.parse(::Type{TID}, s::AbstractString) = TID(s)
Base.convert(::Type{TID}, s::AbstractString) = TID(s)
Base.convert(::Type{TID}, t::TID) = t
Base.convert(::Type{RecordKey}, t::TID) = RecordKey(_Unchecked(), t.value)
Base.convert(::Type{String}, t::TID) = t.value
Base.String(t::TID) = t.value
Base.print(io::IO, t::TID) = print(io, t.value)
Base.show(io::IO, t::TID) = print(io, "TID(", repr(t.value), ")")
Base.isless(a::TID, b::TID) = isless(a.value, b.value)

StructUtils.structlike(::Type{TID}) = false
StructUtils.lower(t::TID) = t.value
StructUtils.lift(::Type{TID}, x::AbstractString) = TID(x)

"""
    @tid_str -> TID

Compile-time validated AT Protocol TID literal, e.g. `tid"3jui7kd54zh2y"`.
"""
macro tid_str(s::String)
    return TID(s)
end
