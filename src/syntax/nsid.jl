#= syntax/nsid.jl =#

#=
Grammar (https://atproto.com/specs/nsid):

alpha       = a-z / A-Z
number      = 0-9
delim       = "."
segment     = alpha *( alpha / number / "-" )   (subsequent authority segments may start with digit)
authority   = segment *( delim segment )         (max 253 bytes, at least 2 segments, lowercased)
name        = alpha *( alpha / number )          (max 63 bytes, case-sensitive)
nsid        = authority delim name               (max 317 bytes)
=#

"""
    NSID_RX

Regular expression matching a valid AT Protocol NSID (excluding the 253-byte authority
and 317-byte total length bounds).
"""
const NSID_RX = r"^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(\.[a-zA-Z][a-zA-Z0-9]{0,62})\z"

"""
    valid_nsid_char(c::AbstractChar) -> Bool

Return `true` if `c` is an allowed ASCII character in an NSID (`[a-zA-Z0-9.-]`).
"""
valid_nsid_char(c::AbstractChar) = _is_ascii_alnum(c) || c == '.' || c == '-'

function _validate_nsid_bytes(cu, start::Int, stop::Int)
    n = stop - start + 1
    n <= 0 && return "NSID cannot be empty"
    n > 317 && return "NSID is too long (317 characters max)"

    seg_count = 1
    seg_start = start

    @inbounds for i in start:stop
        b = cu[i]
        if b == UInt8('.')
            seg_len = i - seg_start
            seg_len == 0 && return "NSID parts cannot be empty"
            seg_len > 63 && return "NSID part too long (63 chars max)"
            if seg_count == 1
                _is_ascii_alpha(cu[seg_start]) ||
                    return "NSID first part must start with an ASCII letter"
            end
            (cu[seg_start] == UInt8('-') || cu[i - 1] == UInt8('-')) &&
                return "NSID parts cannot start or end with hyphen"
            seg_count += 1
            seg_start = i + 1
        elseif !(_is_ascii_alnum(b) || b == UInt8('-'))
            return "Disallowed characters in NSID (ASCII letters, digits, dashes, periods only)"
        end
    end

    seg_count < 3 && return "NSID needs at least three parts"

    # seg_start - 1 is the byte index of the final '.'
    authority_len = (seg_start - 1) - start
    authority_len > 253 && return "NSID authority is too long (253 characters max)"

    name_len = stop - seg_start + 1
    name_len == 0 && return "NSID parts cannot be empty"
    name_len > 63 && return "NSID part too long (63 chars max)"

    @inbounds begin
        _is_ascii_alpha(cu[seg_start]) ||
            return "NSID name part must start with an ASCII letter"
        for j in (seg_start + 1):stop
            _is_ascii_alnum(cu[j]) ||
                return "NSID name part must contain only ASCII letters and digits"
        end
    end

    return nothing
end

_validate_nsid(nsid::Union{String, SubString{String}}) =
    _validate_nsid_bytes(codeunits(nsid), 1, ncodeunits(nsid))

_validate_nsid(nsid::AbstractString) = _validate_nsid(String(nsid))

"""
    ensure_valid_nsid(nsid::AbstractString) -> Nothing

Validate `nsid` against the AT Protocol NSID specification, throwing a
[`SyntaxError`](@ref) if invalid.
"""
function ensure_valid_nsid(nsid::AbstractString)
    err = _validate_nsid(nsid)
    isnothing(err) || throw(SyntaxError(:nsid, String(nsid), err))
    return nothing
end

"""
    is_valid_nsid(nsid::AbstractString) -> Bool

Return `true` if `nsid` satisfies the AT Protocol NSID specification.

# Examples
```jldoctest
julia> ATProto.Syntax.is_valid_nsid("app.bsky.feed.post")
true

julia> ATProto.Syntax.is_valid_nsid("com.example.foo2")
true

julia> ATProto.Syntax.is_valid_nsid("only.two")
false
```
"""
is_valid_nsid(nsid::AbstractString) = isnothing(_validate_nsid(nsid))

"""
    ensure_valid_nsid_regex(nsid::AbstractString; pattern=NSID_RX) -> Nothing

Validate `nsid` using `pattern` and AT Protocol length limits, throwing
[`SyntaxError`](@ref) on failure.
"""
function ensure_valid_nsid_regex(nsid::AbstractString; pattern::Regex=NSID_RX)
    ncodeunits(nsid) > 317 && throw(SyntaxError(:nsid, String(nsid), "NSID is too long (317 characters max)"))
    occursin(pattern, nsid) || throw(SyntaxError(:nsid, String(nsid), "NSID didn't validate via regex"))
    last_dot = findlast(==('.'), nsid)::Int
    (last_dot - 1) > 253 && throw(SyntaxError(:nsid, String(nsid), "NSID authority is too long (253 characters max)"))
    return nothing
end

"""
    is_valid_nsid_regex(nsid::AbstractString; pattern=NSID_RX) -> Bool

Return `true` if `nsid` matches `pattern` and satisfies AT Protocol length limits.
"""
function is_valid_nsid_regex(nsid::AbstractString; pattern::Regex=NSID_RX)
    ncodeunits(nsid) > 317 && return false
    occursin(pattern, nsid) || return false
    last_dot = findlast(==('.'), nsid)::Int
    return (last_dot - 1) <= 253
end

function _normalize_nsid_parts(s::AbstractString)
    last_dot = findlast(==('.'), s)::Int
    auth_rev = lowercase(SubString(s, 1, last_dot - 1))
    name_part = SubString(s, last_dot + 1)
    return string(auth_rev, '.', name_part), last_dot
end

"""
    NSID(s::AbstractString)
    NSID(authority::AbstractString, name::AbstractString)

Validated AT Protocol Namespaced Identifier (NSID), e.g. `app.bsky.feed.post`.

The authority segments are normalized to lowercase while the `name` segment
preserves its original casing. When constructed from `(authority, name)`,
`authority` is given in standard domain order (e.g. `"feed.bsky.app"`) and
reversed internally into NSID order (`"app.bsky.feed.post"`).

Can also be constructed with `parse(NSID, s)`, `tryparse(NSID, s)`, or the
compile-time string macro `nsid"app.bsky.feed.post"`.
"""
struct NSID
    value::String
    last_dot::Int

    NSID(::_Unchecked, value::String, last_dot::Int) = new(value, last_dot)

    function NSID(s::AbstractString)
        ensure_valid_nsid(s)
        normalized, last_dot = _normalize_nsid_parts(s)
        return new(normalized, last_dot)
    end

    function NSID(authority::AbstractString, name::AbstractString)
        isempty(authority) && throw(SyntaxError(:nsid, String(authority), "NSID authority cannot be empty"))
        rev_auth = join(Iterators.reverse(collect(eachsplit(authority, '.'))), '.')
        return NSID(string(rev_auth, '.', name))
    end
end

NSID(; authority::AbstractString, name::AbstractString) = NSID(authority, name)

"""
    nsid(n::NSID) -> String

Return the canonical NSID string (e.g. `"app.bsky.feed.post"`).
"""
nsid(n::NSID) = n.value

"""
    authority(n::NSID) -> String

Return the domain authority in standard (non-reversed) domain order
(e.g. `"feed.bsky.app"` for `NSID("app.bsky.feed.post")`).
"""
function authority(n::NSID)
    auth_rev = SubString(n.value, 1, n.last_dot - 1)
    return join(Iterators.reverse(collect(eachsplit(auth_rev, '.'))), '.')
end

"""
    name(n::NSID) -> String

Return the final name segment of `n` (e.g. `"post"` for `NSID("app.bsky.feed.post")`).
"""
name(n::NSID) = String(SubString(n.value, n.last_dot + 1))

function Base.tryparse(::Type{NSID}, s::AbstractString)
    is_valid_nsid(s) || return nothing
    normalized, last_dot = _normalize_nsid_parts(s)
    return NSID(_Unchecked(), normalized, last_dot)
end

Base.parse(::Type{NSID}, s::AbstractString) = NSID(s)
Base.convert(::Type{NSID}, s::AbstractString) = NSID(s)
Base.convert(::Type{NSID}, n::NSID) = n
Base.convert(::Type{String}, n::NSID) = n.value
Base.String(n::NSID) = n.value
Base.print(io::IO, n::NSID) = print(io, n.value)
Base.show(io::IO, n::NSID) = print(io, "NSID(", repr(n.value), ")")
Base.isless(a::NSID, b::NSID) = isless(a.value, b.value)

StructUtils.structlike(::Type{NSID}) = false
StructUtils.lower(n::NSID) = n.value
StructUtils.lift(::Type{NSID}, x::AbstractString) = NSID(x)

"""
    @nsid_str -> NSID

Compile-time validated AT Protocol NSID literal, e.g. `nsid"app.bsky.feed.post"`.
"""
macro nsid_str(s::String)
    return NSID(s)
end
