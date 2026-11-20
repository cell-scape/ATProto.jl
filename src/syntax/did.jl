#= syntax/did.jl =#

"""
    DID_CHARS_RX

Regular expression matching strings composed solely of valid DID ASCII characters.
"""
const DID_CHARS_RX = r"^[a-zA-Z0-9._:%-]*\z"

"""
    DID_RX

Regular expression matching a valid AT Protocol DID string (excluding the 2048-byte limit).
"""
const DID_RX = r"^did:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]\z"

@inline _is_did_byte(b::UInt8) =
    _is_ascii_alnum(b) || b == UInt8('.') || b == UInt8('_') ||
    b == UInt8(':') || b == UInt8('%') || b == UInt8('-')

"""
    valid_did_char(c::AbstractChar) -> Bool

Return `true` if `c` is an allowed ASCII character in a DID (`[a-zA-Z0-9._:%-]`).
"""
valid_did_char(c::AbstractChar) =
    _is_ascii_alnum(c) || c == '.' || c == '_' || c == ':' || c == '%' || c == '-'

"""
    valid_did_chars(did::AbstractString; pattern=DID_CHARS_RX) -> Bool

Return `true` if `did` consists solely of valid DID characters.
"""
valid_did_chars(did::AbstractString; pattern::Regex=DID_CHARS_RX) =
    occursin(pattern, did)

function _validate_did_bytes(cu, start::Int, stop::Int)
    n = stop - start + 1
    n > 2048 && return "DID is too long (2048 characters max)"
    @inbounds if n < 4 || cu[start] != UInt8('d') || cu[start + 1] != UInt8('i') ||
                 cu[start + 2] != UInt8('d') || cu[start + 3] != UInt8(':')
        return "DID requires 'did:' prefix"
    end

    method_start = start + 4
    i = method_start
    @inbounds while i <= stop && cu[i] != UInt8(':')
        _is_ascii_lower(cu[i]) || return "DID method must be lowercase ASCII letters"
        i += 1
    end
    i == method_start && return "DID method must be lowercase ASCII letters"
    i > stop && return "DID requires prefix, method, and method-specific content"

    id_start = i + 1
    id_start > stop && return "DID requires prefix, method, and method-specific content"

    @inbounds for j in id_start:stop
        _is_did_byte(cu[j]) ||
            return "Disallowed characters in DID (ASCII letters, digits, - : % . _ only)"
    end

    @inbounds last_b = cu[stop]
    (last_b == UInt8(':') || last_b == UInt8('%')) &&
        return "DID cannot end with ':' or '%'"

    return nothing
end

_validate_did(did::Union{String, SubString{String}}) =
    _validate_did_bytes(codeunits(did), 1, ncodeunits(did))

_validate_did(did::AbstractString) = _validate_did(String(did))

"""
    ensure_valid_did(did::AbstractString) -> Nothing

Validate `did` against the AT Protocol DID syntax specification, throwing
a [`SyntaxError`](@ref) if invalid.

Constraints:
- ASCII characters `[a-zA-Z0-9._:%-]` only
- Starts with lowercase `"did:"`
- Method name is one or more lowercase ASCII letters followed by `':'`
- Method-specific identifier is non-empty and cannot end with `':'` or `'%'`
- Overall length at most 2048 bytes
"""
function ensure_valid_did(did::AbstractString)
    err = _validate_did(did)
    isnothing(err) || throw(SyntaxError(:did, String(did), err))
    return nothing
end

"""
    is_valid_did(did::AbstractString) -> Bool

Return `true` if `did` satisfies the AT Protocol DID syntax specification.

# Examples
```jldoctest
julia> ATProto.Syntax.is_valid_did("did:plc:z72i7hdynmk6r22z27h6tvur")
true

julia> ATProto.Syntax.is_valid_did("did:PLC:abc")
false
```
"""
is_valid_did(did::AbstractString) = isnothing(_validate_did(did))

"""
    ensure_valid_did_regex(did::AbstractString; pattern=DID_RX) -> Nothing

Validate `did` using `pattern` and the 2048-byte length limit, throwing
[`SyntaxError`](@ref) on failure.
"""
function ensure_valid_did_regex(did::AbstractString; pattern::Regex=DID_RX)
    ncodeunits(did) > 2048 && throw(SyntaxError(:did, String(did), "DID is too long (2048 characters max)"))
    occursin(pattern, did) || throw(SyntaxError(:did, String(did), "DID didn't validate via regex"))
    return nothing
end

"""
    is_valid_did_regex(did::AbstractString; pattern=DID_RX) -> Bool

Return `true` if `did` matches `pattern` and is at most 2048 bytes.
"""
function is_valid_did_regex(did::AbstractString; pattern::Regex=DID_RX)
    ncodeunits(did) > 2048 && return false
    return occursin(pattern, did)
end

"""
    DID(s::AbstractString)

Validated AT Protocol Decentralized Identifier (DID), e.g. `did:plc:...` or `did:web:...`.

Can also be constructed with `parse(DID, s)`, `tryparse(DID, s)`, or the
compile-time string macro `did"did:plc:z72i7hdynmk6r22z27h6tvur"`.
"""
struct DID
    value::String
    DID(::_Unchecked, value::String) = new(value)
    function DID(s::AbstractString)
        ensure_valid_did(s)
        return new(String(s))
    end
end

"""
    did_method(d::DID) -> SubString{String}

Return the DID method component (e.g. `"plc"` or `"web"`).
"""
function did_method(d::DID)
    colon = findnext(==(':'), d.value, 5)::Int
    return SubString(d.value, 5, colon - 1)
end

"""
    did_identifier(d::DID) -> SubString{String}

Return the method-specific identifier component of `d`.
"""
function did_identifier(d::DID)
    colon = findnext(==(':'), d.value, 5)::Int
    return SubString(d.value, colon + 1)
end

function Base.tryparse(::Type{DID}, s::AbstractString)
    is_valid_did(s) || return nothing
    return DID(_Unchecked(), String(s))
end

Base.parse(::Type{DID}, s::AbstractString) = DID(s)
Base.convert(::Type{DID}, s::AbstractString) = DID(s)
Base.convert(::Type{DID}, d::DID) = d
Base.convert(::Type{String}, d::DID) = d.value
Base.String(d::DID) = d.value
Base.print(io::IO, d::DID) = print(io, d.value)
Base.show(io::IO, d::DID) = print(io, "DID(", repr(d.value), ")")
Base.isless(a::DID, b::DID) = isless(a.value, b.value)

StructUtils.structlike(::Type{DID}) = false
StructUtils.lower(d::DID) = d.value
StructUtils.lift(::Type{DID}, x::AbstractString) = DID(x)

"""
    @did_str -> DID

Compile-time validated AT Protocol DID literal, e.g. `did"did:plc:z72i7hdynmk6r22z27h6tvur"`.
"""
macro did_str(s::String)
    return DID(s)
end
