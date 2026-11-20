#= syntax/datetime.jl =#

@inline _is_leap_year(y::Int) = (y % 4 == 0) && (y % 100 != 0 || y % 400 == 0)

@inline function _days_in_month(y::Int, m::Int)
    m == 2 && return _is_leap_year(y) ? 29 : 28
    (m == 4 || m == 6 || m == 9 || m == 11) && return 30
    return 31
end

@inline function _parse_2digits(cu, i::Int)
    @inbounds begin
        b1 = cu[i]
        b2 = cu[i + 1]
    end
    (_is_ascii_digit(b1) && _is_ascii_digit(b2)) || return -1
    return Int(b1 - UInt8('0')) * 10 + Int(b2 - UInt8('0'))
end

@inline function _parse_4digits(cu, i::Int)
    hi = _parse_2digits(cu, i)
    lo = _parse_2digits(cu, i + 2)
    (hi < 0 || lo < 0) && return -1
    return hi * 100 + lo
end

function _validate_datetime(dt::Union{String, SubString{String}})
    n = ncodeunits(dt)
    n < 20 && return "Datetime is too short (minimum 20 characters, e.g. YYYY-MM-DDTHH:MM:SSZ)"
    n > 64 && return "Datetime is too long (64 characters max)"

    cu = codeunits(dt)
    @inbounds begin
        (cu[5] == UInt8('-') && cu[8] == UInt8('-') &&
         cu[11] == UInt8('T') && cu[14] == UInt8(':') && cu[17] == UInt8(':')) ||
            return "Datetime must follow RFC 3339 format YYYY-MM-DDTHH:MM:SS(.frac)?(Z|±HH:MM)"
    end

    year = _parse_4digits(cu, 1)
    month = _parse_2digits(cu, 6)
    day = _parse_2digits(cu, 9)
    hour = _parse_2digits(cu, 12)
    minute = _parse_2digits(cu, 15)
    second = _parse_2digits(cu, 18)

    (year < 1 || month < 1 || month > 12 || day < 1) &&
        return "Datetime has invalid calendar date (year 0000 is disallowed)"
    day > _days_in_month(year, month) &&
        return "Datetime day is out of range for the given year and month"
    (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) &&
        return "Datetime has invalid time component (leap seconds are disallowed)"

    pos = 20
    @inbounds if cu[pos] == UInt8('.')
        pos += 1
        frac_start = pos
        while pos <= n && _is_ascii_digit(cu[pos])
            pos += 1
        end
        pos == frac_start && return "Datetime fractional seconds must contain at least one digit"
        pos > n && return "Datetime requires a timezone suffix ('Z' or ±HH:MM)"
    end

    @inbounds tz_lead = cu[pos]
    if tz_lead == UInt8('Z')
        pos == n || return "Unexpected trailing characters after 'Z' in datetime"
        return nothing
    elseif tz_lead == UInt8('+') || tz_lead == UInt8('-')
        (pos + 5 == n) || return "Datetime timezone offset must have format ±HH:MM"
        @inbounds cu[pos + 3] == UInt8(':') ||
            return "Datetime timezone offset must have format ±HH:MM"
        tzh = _parse_2digits(cu, pos + 1)
        tzm = _parse_2digits(cu, pos + 4)
        (tzh < 0 || tzh > 23 || tzm < 0 || tzm > 59) &&
            return "Datetime timezone offset is out of range"
        (tz_lead == UInt8('-') && tzh == 0 && tzm == 0) &&
            return "Datetime timezone offset '-00:00' is disallowed (use 'Z' or '+00:00')"
        return nothing
    else
        return "Datetime requires a timezone suffix ('Z' or ±HH:MM)"
    end
end

_validate_datetime(dt::AbstractString) = _validate_datetime(String(dt))

"""
    is_valid_datetime(dt::AbstractString) -> Bool

Return `true` if `dt` conforms to the strict AT Protocol RFC 3339 datetime subset.
"""
is_valid_datetime(dt::AbstractString) = isnothing(_validate_datetime(dt))

"""
    ensure_valid_datetime(dt::AbstractString) -> Nothing

Validate `dt` against the AT Protocol datetime specification, throwing
[`SyntaxError`](@ref) if invalid.
"""
function ensure_valid_datetime(dt::AbstractString)
    err = _validate_datetime(dt)
    isnothing(err) || throw(SyntaxError(:datetime, String(dt), err))
    return nothing
end

"""
    ATDateTime(s::AbstractString)
    ATDateTime(dt::Dates.DateTime)

Validated AT Protocol RFC 3339 timestamp string. Preserves the exact original
timestamp representation (including sub-millisecond precision and timezone offset)
while supporting conversion to UTC `Dates.DateTime`.
"""
struct ATDateTime
    value::String
    ATDateTime(::_Unchecked, value::String) = new(value)
    function ATDateTime(s::AbstractString)
        ensure_valid_datetime(s)
        return new(String(s))
    end
end

function ATDateTime(dt::Dates.DateTime)
    return ATDateTime(_Unchecked(), string(Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS.sss"), "Z"))
end

"""
    Dates.DateTime(dt::ATDateTime) -> Dates.DateTime

Convert an [`ATDateTime`](@ref) to a UTC `Dates.DateTime` (truncated to millisecond
precision, with timezone offset applied).
"""
function Dates.DateTime(dt::ATDateTime)
    cu = codeunits(dt.value)
    n = length(cu)
    year = _parse_4digits(cu, 1)
    month = _parse_2digits(cu, 6)
    day = _parse_2digits(cu, 9)
    hour = _parse_2digits(cu, 12)
    minute = _parse_2digits(cu, 15)
    second = _parse_2digits(cu, 18)

    pos = 20
    ms = 0
    @inbounds if cu[pos] == UInt8('.')
        pos += 1
        scale = 100
        while pos <= n && _is_ascii_digit(cu[pos])
            if scale >= 1
                ms += Int(cu[pos] - UInt8('0')) * scale
                scale ÷= 10
            end
            pos += 1
        end
    end

    base = Dates.DateTime(year, month, day, hour, minute, second, ms)
    @inbounds tz_lead = cu[pos]
    if tz_lead == UInt8('Z')
        return base
    else
        tzh = _parse_2digits(cu, pos + 1)
        tzm = _parse_2digits(cu, pos + 4)
        offset = Dates.Hour(tzh) + Dates.Minute(tzm)
        return tz_lead == UInt8('+') ? (base - offset) : (base + offset)
    end
end

function Base.tryparse(::Type{ATDateTime}, s::AbstractString)
    is_valid_datetime(s) || return nothing
    return ATDateTime(_Unchecked(), String(s))
end

Base.parse(::Type{ATDateTime}, s::AbstractString) = ATDateTime(s)
Base.convert(::Type{ATDateTime}, s::AbstractString) = ATDateTime(s)
Base.convert(::Type{ATDateTime}, dt::ATDateTime) = dt
Base.convert(::Type{ATDateTime}, dt::Dates.DateTime) = ATDateTime(dt)
Base.convert(::Type{String}, dt::ATDateTime) = dt.value
Base.String(dt::ATDateTime) = dt.value
Base.print(io::IO, dt::ATDateTime) = print(io, dt.value)
Base.show(io::IO, dt::ATDateTime) = print(io, "ATDateTime(", repr(dt.value), ")")
Base.isless(a::ATDateTime, b::ATDateTime) = isless(Dates.DateTime(a), Dates.DateTime(b))

StructUtils.structlike(::Type{ATDateTime}) = false
StructUtils.lower(dt::ATDateTime) = dt.value
StructUtils.lift(::Type{ATDateTime}, x::AbstractString) = ATDateTime(x)
