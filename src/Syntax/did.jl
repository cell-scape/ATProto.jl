# DID syntax validation. Port of `packages/syntax/src/did.ts`.
#
# Human-readable constraints:
#  - valid W3C DID (https://www.w3.org/TR/did-core/#did-syntax)
#     - entire URI is ASCII: [a-zA-Z0-9._:%-]
#     - always starts "did:" (lower-case)
#     - method name is one or more lower-case letters, followed by ":"
#     - remaining identifier can have any of the above chars, but can not end
#       with ":" or "%"
#  - in current atproto, only did:plc and did:web are used, but the lexicon
#    layer does not force this
#  - hard length limit of 2KiB

const DID_MAX_LEN = 2048

# NOTE: anchored with \A...\z (not ^...$) to reject trailing newlines, matching
# JavaScript regex semantics exactly.
const DID_REGEX = r"\Adid:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]\z"

"""
    is_valid_did(s) -> Bool

Return `true` if `s` is a syntactically valid DID string
(`did:method:content`, at most 2048 characters).
"""
function is_valid_did(s::AbstractString)::Bool
    return length(s) <= DID_MAX_LEN && occursin(DID_REGEX, s)
end

"""
    ensure_valid_did(s) -> String

Validate that `s` is a valid DID, returning `s`, or throw
[`InvalidDidError`](@ref) with a descriptive message.

The detailed (non-regex) validation mirrors `ensureValidDid` in the TypeScript
reference; use [`is_valid_did`](@ref) for the equivalent regex-based fast path.
"""
function ensure_valid_did(s::AbstractString)::String
    if !startswith(s, "did:")
        throw(InvalidDidError("DID requires \"did:\" prefix"))
    end
    if length(s) > DID_MAX_LEN
        throw(InvalidDidError("DID is too long (2048 chars max)"))
    end
    if endswith(s, ":") || endswith(s, "%")
        throw(InvalidDidError("DID can not end with \":\" or \"%\""))
    end
    # check that all chars are boring ASCII
    if !occursin(r"\A[a-zA-Z0-9._:%-]*\z", s)
        throw(InvalidDidError(
            "Disallowed characters in DID (ASCII letters, digits, and a couple other characters only)",
        ))
    end
    parts = split(s, ":")
    if length(parts) < 3
        throw(InvalidDidError("DID requires prefix, method, and method-specific content"))
    end
    method = parts[2]
    if !occursin(r"\A[a-z]+\z", method)
        throw(InvalidDidError("DID method must be lower-case letters"))
    end
    return String(s)
end

"""
    did_method(s) -> String

Return the method component of a valid DID (e.g. `"plc"` for
`"did:plc:abc123"`). Throws [`InvalidDidError`](@ref) if `s` is not a valid
DID.
"""
function did_method(s::AbstractString)::String
    ensure_valid_did(s)
    return String(split(s, ":")[2])
end
