# AtIdentifier (DID or handle) dispatch. Port of
# `packages/syntax/src/at-identifier.ts`.

"""
    is_did_identifier(s) -> Bool

Return `true` if the at-identifier string `s` is a DID (starts with
`"did:"`) rather than a handle.
"""
is_did_identifier(s::AbstractString)::Bool = startswith(s, "did:")

"""
    is_handle_identifier(s) -> Bool

Return `true` if the at-identifier string `s` is a handle (does not start
with `"did:"`).
"""
is_handle_identifier(s::AbstractString)::Bool = !is_did_identifier(s)

"""
    is_valid_at_identifier(s) -> Bool

Return `true` if `s` is a valid at-identifier — either a valid DID or a
valid handle.
"""
function is_valid_at_identifier(s::AbstractString)::Bool
    return is_did_identifier(s) ? is_valid_did(s) : is_valid_handle(s)
end

"""
    ensure_valid_at_identifier(s) -> String

Validate that `s` is a valid at-identifier (DID or handle), returning `s`,
or throw [`InvalidAtIdentifierError`](@ref).
"""
function ensure_valid_at_identifier(s::AbstractString)::String
    if isempty(s)
        throw(InvalidAtIdentifierError("Invalid DID or handle: identifier must be a non-empty string"))
    end
    try
        if is_did_identifier(s)
            is_valid_did(s) || throw(InvalidDidError("DID didn't validate via regex"))
        else
            is_valid_handle(s) ||
                throw(InvalidHandleError("Handle didn't validate via regex"))
        end
    catch err
        err isa ATProtoSyntaxError || rethrow()
        throw(InvalidAtIdentifierError("Invalid DID or handle: $(err.msg)"))
    end
    return String(s)
end
