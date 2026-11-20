#= syntax/handle.jl =#

const INVALID_HANDLE = "handle.invalid"

"""
    DISALLOWED_TLDS

Tuple of reserved TLDs that are disallowed in handles at registration time.
"""
const DISALLOWED_TLDS = (
    ".local",
    ".arpa",
    ".invalid",
    ".localhost",
    ".internal",
    ".example",
    ".alt",
    ".onion",
)

"""
    VALID_HANDLE_RX

Regular expression matching a valid AT Protocol handle (excluding the 253-byte length bound).
"""
const VALID_HANDLE_RX = r"^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z"

"""
    HANDLE_CHARS_RX

Regular expression matching strings composed solely of valid handle ASCII characters.
"""
const HANDLE_CHARS_RX = r"^[a-zA-Z0-9.-]*\z"

"""
    valid_handle_char(c::AbstractChar) -> Bool

Validate a single character in a handle. Only ASCII letters, digits, periods,
and hyphens are allowed.

# Examples
```jldoctest
julia> ATProto.Syntax.valid_handle_char('a')
true

julia> ATProto.Syntax.valid_handle_char('#')
false

julia> ATProto.Syntax.valid_handle_char('α')
false
```
"""
valid_handle_char(c::AbstractChar) = _is_ascii_alnum(c) || c == '.' || c == '-'

"""
    valid_handle_chars(handle::AbstractString; pattern=HANDLE_CHARS_RX) -> Bool

Return `true` if `handle` contains only characters permitted in an AT Protocol handle.
"""
valid_handle_chars(handle::AbstractString; pattern::Regex=HANDLE_CHARS_RX) =
    occursin(pattern, handle)

function _validate_handle_bytes(cu, start::Int, stop::Int)
    n = stop - start + 1
    n <= 0 && return "Handle cannot be empty"
    n > 253 && return "Handle is too long (253 chars max)"

    label_count = 1
    label_start = start

    @inbounds for i in start:stop
        b = cu[i]
        if b == UInt8('.')
            label_len = i - label_start
            label_len == 0 && return "Handle parts cannot be empty"
            label_len > 63 && return "Handle part too long (max 63 chars)"
            (cu[label_start] == UInt8('-') || cu[i - 1] == UInt8('-')) &&
                return "Handle parts cannot start or end with hyphens"
            label_count += 1
            label_start = i + 1
        elseif !(_is_ascii_alnum(b) || b == UInt8('-'))
            return "Disallowed characters in handle (ASCII letters, digits, dashes, periods only)"
        end
    end

    tld_len = stop - label_start + 1
    tld_len == 0 && return "Handle parts cannot be empty"
    tld_len > 63 && return "Handle part too long (max 63 chars)"
    label_count < 2 && return "Handle domain needs at least two parts"

    @inbounds begin
        _is_ascii_alpha(cu[label_start]) ||
            return "Handle final component (TLD) must start with an ASCII letter"
        (cu[label_start] == UInt8('-') || cu[stop] == UInt8('-')) &&
            return "Handle parts cannot start or end with hyphens"
    end

    return nothing
end

_validate_handle(handle::Union{String, SubString{String}}) =
    _validate_handle_bytes(codeunits(handle), 1, ncodeunits(handle))

_validate_handle(handle::AbstractString) = _validate_handle(String(handle))

"""
    is_valid_handle(handle::AbstractString) -> Bool

Return `true` if `handle` satisfies the AT Protocol handle syntax specification.

Constraints:
- ASCII letters, digits, hyphens, and periods only (`[a-zA-Z0-9.-]`)
- Overall length at most 253 bytes
- At least two dot-separated labels, each 1–63 characters
- Labels cannot start or end with a hyphen (`-`)
- Final label (TLD) must start with an ASCII letter

Does not validate DNS existence or reject reserved TLDs (see [`is_valid_tld`](@ref)).

# Examples
```jldoctest
julia> ATProto.Syntax.is_valid_handle("bsky.app")
true

julia> ATProto.Syntax.is_valid_handle("handle.invalid")
true

julia> ATProto.Syntax.is_valid_handle("no-tld")
false
```
"""
is_valid_handle(handle::AbstractString) = isnothing(_validate_handle(handle))

"""
    ensure_valid_handle(handle::AbstractString) -> Nothing

Validate `handle` against the AT Protocol handle syntax specification, throwing
a [`SyntaxError`](@ref) if invalid.
"""
function ensure_valid_handle(handle::AbstractString)
    err = _validate_handle(handle)
    isnothing(err) || throw(SyntaxError(:handle, String(handle), err))
    return nothing
end

"""
    is_valid_handle_regex(handle::AbstractString; pattern=VALID_HANDLE_RX) -> Bool

Validate a handle by matching against `pattern` and enforcing the 253-byte limit.
"""
function is_valid_handle_regex(handle::AbstractString; pattern::Regex=VALID_HANDLE_RX)
    ncodeunits(handle) > 253 && return false
    return occursin(pattern, handle)
end

"""
    ensure_valid_handle_regex(handle::AbstractString; pattern=VALID_HANDLE_RX) -> Nothing

Validate a handle against `pattern` and the 253-byte limit, throwing [`SyntaxError`](@ref)
on failure.
"""
function ensure_valid_handle_regex(handle::AbstractString; pattern::Regex=VALID_HANDLE_RX)
    ncodeunits(handle) > 253 && throw(SyntaxError(:handle, String(handle), "Handle is too long (253 chars max)"))
    occursin(pattern, handle) || throw(SyntaxError(:handle, String(handle), "Handle didn't validate via regex"))
    return nothing
end

"""
    normalize_handle(handle::AbstractString) -> String

Normalize `handle` to lowercase ASCII. Handles are case-insensitive.
"""
normalize_handle(handle::AbstractString) = lowercase(String(handle))

"""
    normalize_and_ensure_valid_handle(handle::AbstractString) -> String

Normalize `handle` to lowercase, validate it (throwing [`SyntaxError`](@ref) if invalid),
and return the normalized handle string.
"""
function normalize_and_ensure_valid_handle(handle::AbstractString)
    normalized = normalize_handle(handle)
    ensure_valid_handle(normalized)
    return normalized
end

"""
    is_valid_tld(handle::AbstractString) -> Bool

Return `true` if `handle` does not end with a disallowed/reserved TLD
(case-insensitive).

# Examples
```jldoctest
julia> ATProto.Syntax.is_valid_tld("example.com")
true

julia> ATProto.Syntax.is_valid_tld("handle.invalid")
false

julia> ATProto.Syntax.is_valid_tld("EXAMPLE.LOCAL")
false
```
"""
function is_valid_tld(handle::AbstractString)
    lower = lowercase(handle)
    return !any(tld -> endswith(lower, tld), DISALLOWED_TLDS)
end

"""
    Handle(s::AbstractString)

Validated, lowercase-normalized AT Protocol handle.

Can also be constructed with `parse(Handle, s)`, `tryparse(Handle, s)`, or the
compile-time string macro `handle"bsky.app"`.
"""
struct Handle
    value::String
    Handle(::_Unchecked, value::String) = new(value)
    function Handle(s::AbstractString)
        ensure_valid_handle(s)
        return new(lowercase(String(s)))
    end
end

function Base.tryparse(::Type{Handle}, s::AbstractString)
    is_valid_handle(s) || return nothing
    return Handle(_Unchecked(), lowercase(String(s)))
end

Base.parse(::Type{Handle}, s::AbstractString) = Handle(s)
Base.convert(::Type{Handle}, s::AbstractString) = Handle(s)
Base.convert(::Type{Handle}, h::Handle) = h
Base.convert(::Type{String}, h::Handle) = h.value
Base.String(h::Handle) = h.value
Base.print(io::IO, h::Handle) = print(io, h.value)
Base.show(io::IO, h::Handle) = print(io, "Handle(", repr(h.value), ")")
Base.isless(a::Handle, b::Handle) = isless(a.value, b.value)

StructUtils.structlike(::Type{Handle}) = false
StructUtils.lower(h::Handle) = h.value
StructUtils.lift(::Type{Handle}, x::AbstractString) = Handle(x)

"""
    @handle_str -> Handle

Compile-time validated AT Protocol handle literal, e.g. `handle"bsky.app"`.
"""
macro handle_str(s::String)
    return Handle(s)
end
