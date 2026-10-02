"""
    ATProtoSyntaxError <: Exception

Abstract supertype of all syntax validation errors in `ATProto.Syntax`.
Concrete subtypes carry a human-readable `msg` and mirror the error types of
the TypeScript reference (`packages/syntax`).
"""
abstract type ATProtoSyntaxError <: Exception end

for (name, kind) in (
    (:InvalidDidError, "DID"),
    (:InvalidHandleError, "handle"),
    (:InvalidAtIdentifierError, "at-identifier (DID or handle)"),
    (:InvalidNsidError, "NSID"),
    (:InvalidTidError, "TID"),
    (:InvalidRecordKeyError, "record key"),
    (:InvalidAtUriError, "AT-URI"),
    (:InvalidDatetimeError, "datetime"),
)
    @eval begin
        """
            $(nameof($name))(msg::AbstractString)

        Thrown when a string is not a valid atproto $($kind).
        """
        struct $(name) <: ATProtoSyntaxError
            msg::String
        end

        Base.showerror(io::IO, err::$(name)) = print(io, $(name), ": ", err.msg)
    end
end
