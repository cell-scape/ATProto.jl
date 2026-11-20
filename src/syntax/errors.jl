#= syntax/errors.jl =#

"""
    ATProtoError <: Exception

Abstract base type for exceptions thrown by `ATProto`.
"""
abstract type ATProtoError <: Exception end

"""
    SyntaxError <: ATProtoError

Exception thrown when parsing or validating an AT Protocol syntax primitive
(handle, DID, NSID, record key, TID, datetime, or AT-URI) fails.
"""
struct SyntaxError <: ATProtoError
    kind::Symbol
    input::String
    reason::String
end

function Base.showerror(io::IO, e::SyntaxError)
    print(io, "SyntaxError (invalid ", e.kind, " ", repr(e.input), "): ", e.reason)
end

# Internal tag used to bypass redundant validation in `tryparse` / internal constructors.
struct _Unchecked end
