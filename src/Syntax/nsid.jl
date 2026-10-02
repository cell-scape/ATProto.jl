# NSID (Namespaced Identifier) syntax. Port of `packages/syntax/src/nsid.ts`.
#
# Grammar (from the TS reference):
#
#   alpha     = a..z / A..Z
#   number    = 1..9 / 0
#   delim     = "."
#   segment   = alpha *( alpha / number / "-" )
#   authority = segment *( delim segment )   -- valid domain, reversed
#   name      = alpha *( alpha / number )
#   nsid      = authority delim name
#
# Human readable constraints:
#  - a valid domain in reversed notation, followed by an additional
#    period-separated name
#  - at most 317 characters (253 + 1 + 63)
#  - every part: 1..63 chars, no leading/trailing hyphen
#  - first part may not start with a digit
#  - name part: letters/digits only, no leading digit

const NSID_MAX_LEN = 253 + 1 + 63

const NSID_REGEX = r"\A[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?:\.[a-zA-Z](?:[a-zA-Z0-9]{0,62})?)\z"

"""
    NSID

An immutable, validated NSID (Namespaced Identifier), e.g.
`"com.example.status"`.

Fields:
- `segments::Vector{String}` — the period-separated parts

Construction validates the input and throws [`InvalidNsidError`](@ref) on
invalid syntax. See also [`make_nsid`](@ref) and [`parse_nsid`](@ref).
"""
struct NSID
    """Period-separated segments, e.g. `["com", "example", "status"]`."""
    segments::Vector{String}

    """
        NSID(nsid::AbstractString)

    Parse and validate an NSID string, throwing [`InvalidNsidError`](@ref)
    on invalid syntax.
    """
    function NSID(nsid::AbstractString)
        return new(parse_nsid(nsid))
    end
end

"""
    NSID(nsid::NSID)

Identity constructor — `NSID` is immutable, no clone is performed.
"""
NSID(nsid::NSID) = nsid

"""
    parse_nsid(s) -> Vector{String}

Validate `s` as an NSID and return its segments. Throws
[`InvalidNsidError`](@ref) with a descriptive message on invalid syntax.
"""
function parse_nsid(s::AbstractString)::Vector{String}
    if length(s) > NSID_MAX_LEN
        throw(InvalidNsidError("NSID is too long (317 chars max)"))
    end
    if !occursin(r"\A[a-zA-Z0-9.-]*\z", s)
        throw(InvalidNsidError(
            "Disallowed characters in NSID (ASCII letters, digits, dashes, periods only)",
        ))
    end
    segs = split(s, ".")
    # concrete construction keeps inference stable for AbstractString subtypes
    segments = Vector{String}(undef, length(segs))
    for (i, seg) in enumerate(segs)
        segments[i] = String(seg)
    end
    if length(segments) < 3
        throw(InvalidNsidError("NSID needs at least three parts"))
    end
    for seg in segments
        if isempty(seg)
            throw(InvalidNsidError("NSID parts can not be empty"))
        end
        if length(seg) > 63
            throw(InvalidNsidError("NSID part too long (max 63 chars)"))
        end
        if startswith(seg, "-") || endswith(seg, "-")
            throw(InvalidNsidError("NSID parts can not start or end with hyphen"))
        end
    end
    if occursin(r"\A\d", first(segments))
        throw(InvalidNsidError("NSID first part may not start with a digit"))
    end
    name = last(segments)
    # name must be letters and digits only, with no leading digit
    if occursin(r"\A\d", name) || occursin("-", name)
        throw(InvalidNsidError(
            "NSID name part must be only letters and digits (and no leading digit)",
        ))
    end
    return segments
end

"""
    is_valid_nsid(s) -> Bool

Return `true` if `s` is a valid NSID string. Uses the (faster) regex
validation; use [`parse_nsid`](@ref) for detailed error messages.
"""
function is_valid_nsid(s::AbstractString)::Bool
    return length(s) <= NSID_MAX_LEN && length(s) >= 5 &&
           occursin(NSID_REGEX, s)
end

"""
    ensure_valid_nsid(s) -> String

Validate that `s` is a valid NSID, returning `s`, or throw
[`InvalidNsidError`](@ref) with a descriptive message.
"""
function ensure_valid_nsid(s::AbstractString)::String
    parse_nsid(s)
    return String(s)
end

"""
    make_nsid(authority, name) -> NSID

Build an [`NSID`](@ref) from a (non-reversed) domain authority and a name,
e.g. `make_nsid("example.com", "status") == NSID("com.example.status")`.
"""
function make_nsid(authority::AbstractString, name::AbstractString)::NSID
    auth_parts = split(authority, ".")
    segs = Vector{String}(undef, length(auth_parts) + 1)
    for (i, p) in enumerate(Iterators.reverse(auth_parts))
        segs[i] = String(p)
    end
    segs[end] = String(name)
    return NSID(join(segs, "."))
end

"""
    nsid_authority(nsid) -> String

Return the (reversed-back-to-normal) domain authority of an NSID, e.g.
`"example.com"` for `"com.example.status"`.
"""
function nsid_authority(nsid::NSID)::String
    return join(reverse(nsid.segments[1:end-1]), ".")
end

nsid_authority(nsid::AbstractString)::String = nsid_authority(NSID(nsid))

"""
    nsid_name(nsid) -> String

Return the final name segment of an NSID, e.g. `"status"` for
`"com.example.status"`.
"""
nsid_name(nsid::NSID)::String = last(nsid.segments)

nsid_name(nsid::AbstractString)::String = nsid_name(NSID(nsid))

Base.string(nsid::NSID)::String = join(nsid.segments, ".")
Base.print(io::IO, nsid::NSID) = print(io, string(nsid))
Base.:(==)(a::NSID, b::NSID) = string(a) == string(b)
Base.:(==)(a::NSID, b::AbstractString) = string(a) == b
Base.:(==)(a::AbstractString, b::NSID) = a == string(b)
Base.hash(nsid::NSID, h::UInt) = hash(string(nsid), h)
