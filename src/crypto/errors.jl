"""
    ATProtoCryptoError <: Exception

Abstract supertype of all crypto/encoding errors in `ATProto.Crypto`.
"""
abstract type ATProtoCryptoError <: Exception end

for (name, kind) in (
    (:InvalidMultibaseError, "multibase string"),
    (:InvalidCidError, "CID"),
    (:InvalidMultikeyError, "multikey / did:key"),
    (:UnsupportedKeyTypeError, "key type"),
)
    @eval begin
        """
            $(nameof($name))(msg::AbstractString)

        Thrown when a value is not a valid atproto $($kind).
        """
        struct $(name) <: ATProtoCryptoError
            msg::String
        end

        Base.showerror(io::IO, err::$(name)) = print(io, $(name), ": ", err.msg)
    end
end
