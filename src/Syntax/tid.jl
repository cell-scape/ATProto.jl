# TID (Timestamp Identifier) syntax and codec.
# Validation ported from `packages/syntax/src/tid.ts`; integer codec per the
# atproto TID spec (https://atproto.com/specs/tid) and `atproto-py`.
#
# A TID is a 13-character base32-sortable string (RFC 4648 "base32" alphabet,
# no padding: "234567abcdefghijklmnopqrstuvwxyz") encoding a 64-bit integer:
#
#   - the top bit is always 0 (first character is in "234567abcdefghij")
#   - the next 53 bits are microseconds since the Unix epoch
#   - the low 10 bits are a "clock id"

const TID_LEN = 13
const TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz"
const TID_REGEX = r"\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z"

# Unix epoch as a Julia DateTime.
const _TID_EPOCH = DateTime(1970, 1, 1)

"""
    is_valid_tid(s) -> Bool

Return `true` if `s` is a syntactically valid TID (13 characters of the
base32-sortable alphabet with the high bit unset).
"""
function is_valid_tid(s::AbstractString)::Bool
    return length(s) == TID_LEN && occursin(TID_REGEX, s)
end

"""
    ensure_valid_tid(s) -> String

Validate that `s` is a valid TID, returning `s`, or throw
[`InvalidTidError`](@ref).
"""
function ensure_valid_tid(s::AbstractString)::String
    if length(s) != TID_LEN
        throw(InvalidTidError("TID must be 13 characters"))
    end
    if !occursin(TID_REGEX, s)
        throw(InvalidTidError("TID syntax not valid (regex)"))
    end
    return String(s)
end

"""
    TID

An immutable, validated TID (Timestamp Identifier) — a 13-character
base32-sortable string encoding a 64-bit integer (53-bit microsecond
timestamp + 10-bit clock id, high bit zero).

Constructors:
- `TID(s::AbstractString)` — validate and wrap a TID string
- `TID(u::UInt64)` — encode a raw 64-bit TID value
- `TID(dt::DateTime; clockid=0)` — build from a timestamp
- `TID(; clockid=0)` — build from the current UTC time
"""
struct TID
    """The 13-character base32-sortable TID string."""
    value::String

    function TID(s::AbstractString)
        return new(ensure_valid_tid(s))
    end
end

TID(tid::TID) = tid

"""
    TID(u::UInt64)

Encode a raw 64-bit TID value. The high bit must be zero.
"""
function TID(u::UInt64)
    return TID(format_tid(u))
end

"""
    TID(dt::DateTime; clockid=0)

Build a TID from a timestamp (interpreted as UTC) and a 10-bit clock id.
"""
function TID(dt::DateTime; clockid::Integer = 0)
    0 <= clockid <= 1023 || throw(ArgumentError("clockid must fit in 10 bits (0..1023)"))
    micros = Int64(floor(Dates.value(Millisecond(dt - _TID_EPOCH)))) * 1000
    u = (UInt64(micros) << 10) | UInt64(clockid)
    return TID(u)
end

"""
    TID(; clockid=0)

Build a TID for the current UTC time.

NOTE: unlike `atproto-py`, this does not guarantee monotonic uniqueness —
callers generating many ids in a tight loop should track the last value.
"""
TID(; clockid::Integer = 0) = TID(Dates.now(Dates.UTC); clockid)

"""
    format_tid(u::UInt64) -> String

Encode a 64-bit integer as its 13-character base32-sortable TID string.
The top bit is masked off (an unset top bit is reserved by the TID spec),
mirroring `NewTIDFromInteger` in the Go reference: 13×5=65 bits are consumed
from the low end, dropping the padding bit.
"""
function format_tid(u::UInt64)::String
    v = u & 0x7fffffffffffffff  # top bit is reserved and always zero
    buf = Vector{UInt8}(undef, TID_LEN)
    for i in TID_LEN:-1:1
        buf[i] = codeunit(TID_ALPHABET, (Int(v & 0x1f) + 1))
        v >>= 5
    end
    return String(buf)
end

"""
    parse_tid(s) -> UInt64

Decode a valid TID string to its 64-bit integer value. Throws
[`InvalidTidError`](@ref) on invalid syntax.
"""
function parse_tid(s::AbstractString)::UInt64
    ensure_valid_tid(s)
    u = UInt64(0)
    for c in s
        idx = findfirst(==(c), TID_ALPHABET)
        idx === nothing && throw(InvalidTidError("TID syntax not valid (regex)"))
        u = (u << 5) | UInt64(idx - 1)
    end
    return u
end

Base.UInt64(tid::TID)::UInt64 = parse_tid(tid.value)
Base.string(tid::TID)::String = tid.value
Base.print(io::IO, tid::TID) = print(io, tid.value)
Base.:(==)(a::TID, b::TID) = a.value == b.value
Base.:(==)(a::TID, b::AbstractString) = a.value == b
Base.:(==)(a::AbstractString, b::TID) = a == b.value
Base.hash(tid::TID, h::UInt) = hash(tid.value, h)
Base.isless(a::TID, b::TID) = isless(a.value, b.value)  # sortable

"""
    tid_timestamp(s) -> DateTime

Return the UTC timestamp encoded in a TID (53-bit microseconds since the
Unix epoch).
"""
function tid_timestamp(s::AbstractString)::DateTime
    u = parse_tid(s)
    micros = Int64((u >> 10) & 0x1fffffffffffff)  # 53-bit mask, as in Go
    return _TID_EPOCH + Microsecond(micros)
end

tid_timestamp(tid::TID)::DateTime = tid_timestamp(tid.value)

"""
    tid_clockid(s) -> Int

Return the 10-bit clock id encoded in a TID (0..1023).
"""
function tid_clockid(s::AbstractString)::Int
    return Int(parse_tid(s) & 0x3ff)
end

tid_clockid(tid::TID)::Int = tid_clockid(tid.value)
