#= syntax/handle.jl =#

const INVALID_HANDLE = "handle.invalid"

"""
DISALLOWED_TLDS::Vector{String}

A list of reserved TLDs that are disallowed in handles at registration time.
"""
const DISALLOWED_TLDS = [
    ".local",
    ".arpa",
    ".invalid",
    ".localhost",
    ".internal",
    ".example",
    ".alt",
    ".onion",
]

"""
VALID_HANDLE_RX::Regex

A regular expression that will match a valid handle.

"""
const VALID_HANDLE_RX = r"^([a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"

"""
HANDLE_CHARS_RX::Regex

A regular expression that will match characters in a valid handle.
"""
const HANDLE_CHARS_RX = r"^[a-zA-Z0-9.-]*$"

"""
valid_handle_char(c::Char)::Bool

Validate a character in a handle. Only ASCII letters, digits, period, and hyphens are allowed.

# Arguments
- `c::Char`: A character from a handle string

# Returns
- `::Bool`: Returns true when a character is valid

# Examples
```julia-repl
julia> valid_handle_char('a')
true
julia> valid_handle_char('#')
false
julia> all(valid_handle_char, "example.com")
true
```
"""
valid_handle_char(c::Char)::Bool = isletter(c) || isdigit(c) || c in ('.', '-')

"""
valid_handle_chars(handle::String)::Bool

Validate characters in a handle string

# Arguments
- `handle::String`: Handle string

# Returns
- `::Bool`: Returns true if handle matches HANDLE_CHARS_RX

# Examples
```julia-repl
julia> valid_handle_chars("example.com")
true
julia> valid_handle_chars("no-tld")
false
```
"""
valid_handle_chars(handle; pattern=HANDLE_CHARS_RX)::Bool = !isnothing(match(pattern, handle))

"""
ensure_valid_handle(handle::String)::Bool

Ensure that a handle is valid. 

Handle constraints, in English:
- Must be a possible domain name
    - RFC-1035, RFC-3696, RFC-3986
    - "labels" (sub-names) are made of ASCII letters, digits, and hyphens
    - can not start or end with a hyphen
    - TLD (last component) should not start with a digit
    - can not end with a hyphen (can end with a digit)
    - each segment must be between 1 and 63 characters (not including any periods)
    - overall length can not be more than 253 characters
    - separated by (ASCII) periods; does not start or end with a period
    - case insensitive
    - domains (handles) are equal if they are the same lower-case
    - punycode allowed for internationalization
- no whitespace, null bytes, joining chars, etc
- does not validate whether domain or TLD exists, or is a reserved or special TLD (eg, .onion or .local)
- does not validate punycode

# Arguments
- `handle::String`: Handle string to test for validity

# Returns
- `::Bool`: Returns false on first failed constraint, true otherwise

# Examples
```julia-repl
julia> ensure_valid_handle("handle.invalid")
true
julia> ensure_valid_handle("no-tld")
false
```
"""
function is_valid_handle(handle)::Bool
    !all(valid_handle_char, handle) && return false

    length(handle) > 253 && return false
    
    labels = split(handle, '.')
    length(labels) < 2 && return false

    !isletter(first(last(labels))) && return false

    for label in labels
        isempty(label) && return false
        length(label) > 63 && return false
        (startswith(label, '-') || endswith(label, '-')) && return false
    end

    return true
end

"""
ensure_valid_handle(handle::String)::Nothing

Ensure that a handle is valid. 

Handle constraints, in English:
- Must be a possible domain name
    - RFC-1035, RFC-3696, RFC-3986
    - "labels" (sub-names) are made of ASCII letters, digits, and hyphens
    - can not start or end with a hyphen
    - TLD (last component) should not start with a digit
    - can not end with a hyphen (can end with a digit)
    - each segment must be between 1 and 63 characters (not including any periods)
    - overall length can not be more than 253 characters
    - separated by (ASCII) periods; does not start or end with a period
    - case insensitive
    - domains (handles) are equal if they are the same lower-case
    - punycode allowed for internationalization
- no whitespace, null bytes, joining chars, etc
- does not validate if domain or TLD exists, or is a reserved or special TLD (eg, .onion or .local)
- does not validate punycode

# Arguments
- `handle::String`: Handle string to test for validity

# Returns
- `::Nothing`: Returns nothing on success, throws otherwise

# Examples
```julia-repl
julia> ensure_valid_handle("example.com")

julia> ensure_valid_handle("no-tld")
ERROR: ...
```
"""
function ensure_valid_handle(handle)::Nothing
    !all(valid_handle_char, handle) && error("Disallowed characters in handle (ASCII letters, digits, dashes, periods only)")
    
    length(handle) > 253 && error("Handle is too long (253 chars max)")
    
    labels = split(handle, '.')
    length(labels) < 2 && error("Handle domain needs at least two parts" )

    !isletter(first(last(labels))) && error("Handle final component (TLD) must start with an ASCII letter" )

    for label in labels
        isempty(label) && error("Handle parts cannot be empty")
        length(label) > 63 && error("Handle part too long (max 63 chars)")        
        (startswith(label, '-') || endswith(label, '-')) && error("Handle parts cannot start or end with hyphens")
    end

    return nothing
end


"""
is_valid_handle_regex(handle::String; pattern::Regex)::Bool

Validate a handle by matching against a regular expression.

# Arguments
- `handle::String`: Handle string to validate

# Returns
- `::Bool`: False if validation fails

# Examples
```julia-repl
julia> is_valid_handle_regex("example.com")
true
julia> is_valid_handle_regex("no-tld")
false
```
"""
function is_valid_handle_regex(handle; pattern=VALID_HANDLE_RX)::Bool
    isnothing(match(pattern, handle)) && return false
    length(handle) > 253 && return false

    return true
end


"""
ensure_valid_handle_regex(handle::String; pattern::Regex)::Nothing

Validate a handle by matching against a regular expression.

# Arguments
- `handle::String`: Handle string to validate

# Returns
- `::Nothing`: throws ErrorException if handle is invalid, nothing otherwise

# Examples
```julia-repl
julia> ensure_valid_handle_regex("example.com")

julia> ensure_valid_handle_regex("no-tld")
ERROR: ...
```
"""
function ensure_valid_handle_regex(handle; pattern=VALID_HANDLE_RX)::Nothing
    isnothing(match(pattern, handle)) && error("Handle didn't validate via regex")
    length(handle) > 253 && error("Handle is too long (253 chars max)")

    return nothing
end


"""
normalize_handle(handle::String)::String

Cast handle to lowercase. Handles are case insensitive.

# Arguments
- `handle::String`: Handle string

# Returns
- `::String`: lowercase handle string

# Examples
```julia-repl
julia> normalize_handle("example.com")
"example.com"
julia> normalize_handle("Example.com")
"example.com"
```
"""
normalize_handle(handle) = lowercase(handle)

"""
normalize_and_ensure_valid_handle(handle::String)::Bool

Normalize handle string and validate.

# Arguments
- `handle::String`: Handle string

# Returns
- `::Bool`: Returns true if handle is valid

# Examples
```julia-repl
julia> normalize_and_ensure_valid_handle("Example.com")
true
julia> normalize_and_ensure_valid_handle("no-tld")
false
```
"""
function normalize_and_ensure_valid_handle(handle)::Nothing
    normalized = normalize_handle(handle)
    return ensure_valid_handle(normalized)
end

"""
is_valid_tld(handle::String)::Bool

Test TLD against disallowed list

# Arguments
- `handle::String`: Handle string

# Returns
- `::Bool`: Returns true if TLD is not in disallowed list

# Examples
```julia-repl
julia> is_valid_tld("example.com")
true
julia> is_valid_tld("handle.invalid")
false
```
"""
is_valid_tld(handle)::Bool = !any(endswith(handle), DISALLOWED_TLDS)
