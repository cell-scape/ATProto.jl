# AT-Identifier (DID or Handle) validation helpers.

"""
    is_valid_at_identifier(s) -> Bool

Return `true` if `s` is either a valid AT Protocol DID or a valid Handle.
"""
function is_valid_at_identifier(s::AbstractString)::Bool
    isempty(s) && return false
    return startswith(s, "did:") ? is_valid_did(s) : is_valid_handle(s)
end

"""
    ensure_valid_at_identifier(s) -> String

Validate that `s` is a valid DID or Handle, throwing [`SyntaxError`](@ref) otherwise.
"""
function ensure_valid_at_identifier(s::AbstractString)::String
    isempty(s) && throw(SyntaxError(:at_identifier, String(s), "identifier must be non-empty"))
    if startswith(s, "did:")
        ensure_valid_did(s)
    else
        ensure_valid_handle(s)
    end
    return String(s)
end
