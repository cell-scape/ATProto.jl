#= syntax/ascii.jl =#

# Strict ASCII byte and character predicates.
# Note: Base.isletter and Base.islowercase match all Unicode letters, whereas
# AT Protocol identifiers (handles, DIDs, NSIDs, record keys, TIDs, AT-URIs)
# strictly permit ASCII only.

@inline _is_ascii_lower(b::UInt8) = UInt8('a') <= b <= UInt8('z')
@inline _is_ascii_upper(b::UInt8) = UInt8('A') <= b <= UInt8('Z')
@inline _is_ascii_alpha(b::UInt8) = _is_ascii_lower(b) || _is_ascii_upper(b)
@inline _is_ascii_digit(b::UInt8) = UInt8('0') <= b <= UInt8('9')
@inline _is_ascii_alnum(b::UInt8) = _is_ascii_alpha(b) || _is_ascii_digit(b)

@inline _is_ascii_lower(c::AbstractChar) = 'a' <= c <= 'z'
@inline _is_ascii_upper(c::AbstractChar) = 'A' <= c <= 'Z'
@inline _is_ascii_alpha(c::AbstractChar) = _is_ascii_lower(c) || _is_ascii_upper(c)
@inline _is_ascii_digit(c::AbstractChar) = '0' <= c <= '9'
@inline _is_ascii_alnum(c::AbstractChar) = _is_ascii_alpha(c) || _is_ascii_digit(c)
