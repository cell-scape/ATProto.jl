# Identity resolution errors.

"""
    HandleNotFoundError <: Exception

Thrown when a handle could not be resolved to a DID (no valid DNS TXT or
well-known record found).
"""
struct HandleNotFoundError <: Exception
    handle::String
end

Base.showerror(io::IO, err::HandleNotFoundError) =
    print(io, "HandleNotFoundError(", err.handle, "): Could not resolve handle")

"""
    IdentityMismatchError <: Exception

Thrown when bidirectional identity verification fails: the DID document's
`alsoKnownAs` handle does not match the handle that resolved to the DID.
"""
struct IdentityMismatchError <: Exception
    handle::String
    did::String
    doc_handle::String
end

function Base.showerror(io::IO, err::IdentityMismatchError)
    print(io, "IdentityMismatchError: handle $(err.handle) resolves to $(err.did), ",
          "but the DID document declares handle $(err.doc_handle)")
end
