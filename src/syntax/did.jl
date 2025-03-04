#= syntax/did.jl =# 

"""
const DID_CHARS_RX::Regex

Regex for valid DID characters.
"""
const DID_CHARS_RX = r"^[a-zA-Z0-9._:%-]*$"

"""
const DID_RX::Regex

Regex for matching a valid DID string
"""
const DID_RX = r"^did:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]$"

"""
valid_did_char(c::Char)::Bool

Test char in DID string for validity

# Arguments
- `c::Char`: Single character in DID string

# Returns
- `::Bool`: Returns true if character is an ASCII letter, digit, period, underscore, colon, dash, or percent sign

# Examples
```julia-repl
julia> valid_did_char('%')
true
julia> valid_did_char('#')
false
```
"""
valid_did_char(c::Char)::Bool = isletter(c) || isdigit(c) || c in ('.', '_', ':', '%', '-')

"""
valid_did_chars(did::String; pattern::Regex)::Bool

Test a DID string against DID character regex

# Arguments
- `did::String`: DID string

# Keyword Arguments
- `pattern::Regex`: Regular expression for valid DID character set

# Returns
- `::Bool`: Returns true if match succeeds

# Examples
```julia-repl
julia> valid_did_chars("did:example-did")
true
julia> valid_did_chars("#did")
false
```
"""
valid_did_chars(did; pattern=DID_CHARS_RX) = !isnothing(match(pattern, did))

"""
ensure_valid_did(did::String)::Nothing

Test DID string for validity.

Constraints:
- valid W3C DID (https://www.w3.org/TR/did-core/#did-syntax)
    - entire URI is ASCII: [a-zA-Z0-9._:%-]
    - always starts with 'did:' (lowercase)
    - method name is one or more lowercase letters followed by ':'
    - remaining identifier can have any of the above chars, but can not end in ":"
    - it seems that a bunch of ":" can be included, and don't need spaces in between
    - '%' is used for 'percent encoding' and must be followed by two hex characters (thus can't end in '%')
    - query ('?') and fragment ('#') stuff is defined for "DID URIs", but not as part of the identifier itself
    - The current specification does not take a position on the maximum length of a DID"
- in current atproto, only allowing did:plc and did:web, but not forcing this at lexicon layer
- hard length limit of 8Kbytes
- not going to validate "percent encoding" here

# Arguments
- `did::String`: DID string to validate

# Returns
- `::Nothing`: Returns nothing on success, throws otherwise

# Examples
```julia-repl
julia> ensure_valid_did(valid_did)

julia> ensure_valid_did(bad_did)
ERROR: ...
```
"""
function ensure_valid_did(did) 
    !startswith(did, "did:") && error("DID requires 'did:' prefix")

    !all(valid_did_char, did) && error("Disallowed characters in DID (ASCII letters, digits, - : % . _ only)")

    did_fields = split(did, ':')
    length(did_fields) < 3 && error("DID requires prefix, method, and method-specific content")

    method = did_fields[2]
    (isempty(method) || !islowercase(method)) && error("DID method must be lowercase letters")

    (endswith(did, ':') || endswith(did, '%')) && error("DID cannot end with ':' or '%'")

    length(did) > 2048 && error("DID is too long (2048 characters max)")

    return nothing
end

"""
is_valid_did(did::String)::Bool

Test for valid DID string

# Arguments
- `did::String`: DID string

# Returns
- `::Bool`: Returns false if DID string fails constraint

# Examples
```julia-repl
julia> is_valid_did("did:method:info")
true
julia> is_valid_did(":::")
false
```
"""
function is_valid_did(did)
    !startswith(did, "did:") && return false
    !all(valid_did_char, did) && return false    
    (endswith(did, ':') || endswith(did, '%')) && return false
    length(did) > 2048 && return false

    did_fields = split(did, ':')
    length(did_fields) < 3 && return false

    method = did_fields[2]
    (isempty(method) || !islowercase(method)) && return false

    return true
end

"""
ensure_valid_did_regex(did::String)::Nothing 

Validate DID with regex

# Arguments
- `did::String`: DID String

# Keyword Arguments
- `pattern::Regex`: DID validation regex

# Returns
- `::Nothing`: Returns nothing on success, throws otherwise

# Examples
```julia-repl
julia> ensure_valid_did(good_did)

julia> ensure_valid_did(bad_did)
ERROR: ...
```
"""
function ensure_valid_did_regex(did; pattern=DID_RX)
    isnothing(match(pattern, did)) && error("DID didn't validate via regex")
    length(did) > 2048 && error("DID is too long (2048 characters max)")
    return nothing
end

"""
is_valid_did_regex(did::String; pattern::Regex)::Bool

Test DID string for validity against regular expression

# Arguments
- `did::String`: DID String

# Keyword Arguments
- `pattern::Regex`: Regular expression to match DID

# Returns
- `::Bool`: Returns false on failure to match

# Examples
```julia-repl
julia> is_valid_did_regex(good_did)
true
julia> is_valid_did_regex(bad_did)
false
```
"""
function is_valid_did_regex(did; pattern=DID_RX)
    isnothing(match(pattern, did)) && return false
    length(did) > 2048 && return false
    return true
end
