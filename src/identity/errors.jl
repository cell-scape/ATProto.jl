#= identity/errors.jl =#

"""
    IdentityError <: ATProtoError

Exception thrown when DID resolution, handle resolution, DID document parsing,
or bidirectional handle verification fails.
"""
struct IdentityError <: ATProtoError
    target::String
    reason::String
end

function Base.showerror(io::IO, e::IdentityError)
    print(io, "IdentityError (", repr(e.target), "): ", e.reason)
end
