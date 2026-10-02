# Handle syntax validation. Port of `packages/syntax/src/handle.ts`.
#
# Handle constraints, in English:
#  - must be a possible domain name (RFC 3696 s2, RFC 3986 s3)
#    - labels (sub-names) are made of ASCII letters, digits, hyphens
#    - can not start or end with a hyphen
#    - TLD (last component) must start with an ASCII letter
#    - each label must be between 1 and 63 characters
#    - overall length at most 253 characters
#    - separated by ASCII periods; no leading/trailing period
#    - case insensitive: handles are equal if the same lower-case
#    - punycode allowed for internationalization (not validated here)
#  - no whitespace, null bytes, joining characters, etc.

"Placeholder handle for accounts whose handle could not be resolved."
const INVALID_HANDLE = "handle.invalid"

# Registration-time (not protocol-level) restrictions; reserved/special TLDs
# that should never resolve in production. See also:
# https://en.wikipedia.org/wiki/Top-level_domain#Reserved_domains
const DISALLOWED_TLDS = (
    ".local",
    ".arpa",
    ".invalid",
    ".localhost",
    ".internal",
    ".example",
    ".alt",
    # policy could conceivably change on ".onion" some day
    ".onion",
    # NOTE: ".test" is allowed in testing and development
)

const HANDLE_MAX_LEN = 253

# labels: [a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])? ; TLD starts with a letter
const HANDLE_REGEX = r"\A([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z"

"""
    is_valid_handle(s) -> Bool

Return `true` if `s` is a syntactically valid handle (domain name), at most
253 characters long.
"""
function is_valid_handle(s::AbstractString)::Bool
    return length(s) <= HANDLE_MAX_LEN && occursin(HANDLE_REGEX, s)
end

"""
    ensure_valid_handle(s) -> String

Validate that `s` is a valid handle, returning `s`, or throw
[`InvalidHandleError`](@ref) with a descriptive message.
"""
function ensure_valid_handle(s::AbstractString)::String
    # check that all chars are boring ASCII
    if !occursin(r"\A[a-zA-Z0-9.-]*\z", s)
        throw(InvalidHandleError(
            "Disallowed characters in handle (ASCII letters, digits, dashes, periods only)",
        ))
    end
    if length(s) > HANDLE_MAX_LEN
        throw(InvalidHandleError("Handle is too long (253 chars max)"))
    end
    labels = split(s, ".")
    if length(labels) < 2
        throw(InvalidHandleError("Handle domain needs at least two parts"))
    end
    for (i, label) in enumerate(labels)
        if isempty(label)
            throw(InvalidHandleError("Handle parts can not be empty"))
        end
        if length(label) > 63
            throw(InvalidHandleError("Handle part too long (max 63 chars)"))
        end
        if startswith(label, "-") || endswith(label, "-")
            throw(InvalidHandleError("Handle parts can not start or end with hyphens"))
        end
        if i == length(labels) && !occursin(r"\A[a-zA-Z]", label)
            throw(InvalidHandleError(
                "Handle final component (TLD) must start with ASCII letter",
            ))
        end
    end
    return String(s)
end

"""
    normalize_handle(s) -> String

Lower-case a handle. Handles are case-insensitive and canonically compared
as lower-case strings.
"""
normalize_handle(s::AbstractString)::String = lowercase(s)

"""
    normalize_and_ensure_valid_handle(s) -> String

Lower-case `s` and validate it as a handle, throwing
[`InvalidHandleError`](@ref) if invalid.
"""
function normalize_and_ensure_valid_handle(s::AbstractString)::String
    normalized = normalize_handle(s)
    ensure_valid_handle(normalized)
    return normalized
end

"""
    is_valid_tld(handle) -> Bool

Return `true` unless the handle ends in a reserved/special-use TLD
(`.local`, `.arpa`, `.invalid`, `.localhost`, `.internal`, `.example`,
`.alt`, `.onion`). These are registration-time restrictions, not syntax
restrictions.
"""
function is_valid_tld(handle::AbstractString)::Bool
    for tld in DISALLOWED_TLDS
        if endswith(handle, tld)
            return false
        end
    end
    return true
end
