# Datetime validation and formatting. Port of
# `packages/syntax/src/datetime.ts`.
#
# atproto datetime strings are the intersection of RFC 3339, ISO 8601 and the
# WHATWG HTML datetime standard:
#   - "YYYY-MM-DDTHH:MM:SS[.ffffff...]Z" or with a "+HH:MM"/"-HH:MM" offset
#   - "T" separator and "Z" designator are upper-case; "-00:00" is rejected
#   - fractional seconds: 1+ digits (at least millisecond precision is
#     canonical on serialization)
#   - seconds 00-59 (no leap seconds); valid calendar dates only; 4-digit
#     years 0000-9999

const DATETIME_MAX_LEN = 64

# Named groups mirror the TS reference; validated semantically afterwards
# (days-in-month, leap seconds) like `new Date()` does there.
const DATETIME_REGEX = r"\A(?<full_year>[0-9]{4})-(?<date_month>0[1-9]|1[012])-(?<date_mday>[0-2][0-9]|3[01])T(?<time_hour>[0-1][0-9]|2[0-3]):(?<time_minute>[0-5][0-9]):(?<time_second>[0-5][0-9]|60)(?<time_secfrac>\.[0-9]+)?(?<time_offset>Z|(?<time_numoffset>[+-](?:[0-1][0-9]|2[0-3]):[0-5][0-9]))\z"

"""
    is_valid_datetime(s) -> Bool

Return `true` if `s` is a valid atproto datetime string (RFC 3339 ∩ ISO 8601
∩ HTML). No leap seconds; `-00:00` is rejected; fractional seconds of any
length are accepted.
"""
function is_valid_datetime(s::AbstractString)::Bool
    return _datetime_capture(s) !== nothing
end

"""
    ensure_datetime_string(s) -> String

Validate that `s` is a valid atproto datetime string, returning `s`, or
throw [`InvalidDatetimeError`](@ref) with a descriptive message.
"""
function ensure_datetime_string(s::AbstractString)::String
    if length(s) > DATETIME_MAX_LEN
        throw(InvalidDatetimeError("datetime is too long (64 chars max)"))
    end
    if endswith(s, "-00:00")
        throw(InvalidDatetimeError("datetime can not use \"-00:00\" for UTC timezone"))
    end
    m = match(DATETIME_REGEX, s)
    if m === nothing
        throw(InvalidDatetimeError(
            "datetime is not in a valid format (must match RFC 3339 & ISO 8601 with 'Z' or ±hh:mm timezone)",
        ))
    end
    msg = _semantic_datetime_message(m)
    msg === nothing || throw(InvalidDatetimeError(msg))
    return String(s)
end
"""Regex-match plus semantic checks (calendar validity, leap seconds).
Returns the match, or `nothing` when the string is not a valid atproto
datetime."""
function _datetime_capture(s::AbstractString)
    (s isa AbstractString && length(s) <= DATETIME_MAX_LEN) || return nothing
    endswith(s, "-00:00") && return nothing
    m = match(DATETIME_REGEX, s)
    m === nothing && return nothing
    _semantic_datetime_message(m) === nothing || return nothing
    return m
end

"""Fetch a regex capture that is guaranteed to have participated, narrowing
the `Union{Nothing,SubString}` (the `error` branch never runs for our
regexes, but keeps type inference concrete)."""
@inline function _cap(m::RegexMatch, name::Symbol)
    v = m[name]
    v === nothing && error("regex capture group :$name did not participate")
    return v
end

"""Return an error message for semantic violations, or `nothing` when OK.
(JS `new Date()` rejects leap seconds and invalid calendar dates.)"""
function _semantic_datetime_message(m::RegexMatch)::Union{String,Nothing}
    # String() wrappers keep inference concrete for AbstractString subtypes
    year = parse(Int, String(_cap(m, :full_year)))
    month = parse(Int, String(_cap(m, :date_month)))
    day = parse(Int, String(_cap(m, :date_mday)))
    second = parse(Int, String(_cap(m, :time_second)))
    if second == 60
        return "datetime did not parse as ISO 8601 (leap seconds are not allowed)"
    end
    # days-in-month (and Feb 29 on leap years) verified by the Date constructor
    try
        Date(year, month, day)
    catch
        return "datetime did not parse as ISO 8601 (invalid calendar date)"
    end
    return nothing
end

"""
    parse_datetime(s) -> DateTime

Parse a valid atproto datetime string into a `Dates.DateTime`, converting
numeric timezone offsets to UTC. Throws [`InvalidDatetimeError`](@ref) on
invalid input.

NOTE: millisecond precision — Julia `DateTime` cannot represent finer
fractional seconds.
"""
function parse_datetime(s::AbstractString)::DateTime
    m = _datetime_capture(s)
    m === nothing && throw(InvalidDatetimeError(
        "datetime is not in a valid format (must match RFC 3339 & ISO 8601 with 'Z' or ±hh:mm timezone)"))
    dt = DateTime(
        parse(Int, String(_cap(m, :full_year))),
        parse(Int, String(_cap(m, :date_month))),
        parse(Int, String(_cap(m, :date_mday))),
        parse(Int, String(_cap(m, :time_hour))),
        parse(Int, String(_cap(m, :time_minute))),
        parse(Int, String(_cap(m, :time_second))),
    )
    # truncate fractional seconds to milliseconds (DateTime precision)
    if m[:time_secfrac] !== nothing
        frac = String(_cap(m, :time_secfrac))[2:min(4, end)]  # strip '.', keep up to 3 digits
        frac = rpad(frac, 3, '0')
        dt += Millisecond(parse(Int, frac))
    end
    # convert numeric offsets to UTC
    if m[:time_numoffset] !== nothing
        off = String(_cap(m, :time_numoffset))
        sign = off[1] == '-' ? -1 : 1
        offset_minutes = sign * (60 * parse(Int, off[2:3]) + parse(Int, off[5:6]))
        dt -= Minute(offset_minutes)
    end
    return dt
end

"""
    datetime_string(dt::DateTime) -> String

Serialize a `DateTime` (interpreted as UTC) to the canonical atproto format
`YYYY-MM-DDTHH:MM:SS.sssZ` — millisecond precision, upper-case `T` and `Z`
(mirrors JS `Date.toISOString()`).
"""
function datetime_string(dt::DateTime)::String
    year = Dates.year(dt)
    0 <= year <= 9999 ||
        throw(InvalidDatetimeError(year < 0 ? "datetime normalized to a negative time" :
                                   "datetime year is too far in the future"))
    return Dates.format(dt, "yyyy-mm-dd\\THH:MM:SS.sss") * "Z"
end

"""
    normalize_datetime(s) -> String

Parse a (leniently accepted) datetime string and normalize it to canonical
UTC atproto form. Falls back to treating timezone-less inputs as UTC.
Throws [`InvalidDatetimeError`](@ref) when nothing parses.
"""
function normalize_datetime(s::AbstractString)::String
    # strict atproto format first
    try
        return datetime_string(parse_datetime(s))
    catch err
        err isa InvalidDatetimeError || rethrow()
    end
    # no explicit timezone: try as UTC
    for suffix in ("Z", " UTC")
        try
            return datetime_string(parse_datetime(s * suffix))
        catch err
            err isa InvalidDatetimeError || rethrow()
        end
    end
    throw(InvalidDatetimeError("datetime did not parse as any timestamp format"))
end
