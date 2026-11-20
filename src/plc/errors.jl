# DID resolution errors. Port of `packages/identity/src/errors.ts` with the
# error types from `packages/did/src/did-error.ts`.

"""
    ATProtoDidError <: Exception

Abstract supertype of DID resolution/validation errors.
"""
abstract type ATProtoDidError <: Exception end

for (name, msg) in (
    (:DidNotFoundError, "Could not resolve DID"),
    (:PoorlyFormattedDidError, "Poorly formatted DID"),
    (:PoorlyFormattedDidDocumentError, "Poorly formatted DID Document"),
    (:UnsupportedDidMethodError, "Unsupported DID method"),
    (:UnsupportedDidWebPathError, "Unsupported did:web paths"),
)
    @eval begin
        """
            $(nameof($name))(did::AbstractString)

        $($msg): `$($msg)` for the given DID.
        """
        struct $(name) <: ATProtoDidError
            did::String
        end

        Base.showerror(io::IO, err::$(name)) =
            print(io, $(name), "(", err.did, "): ", $(msg))
    end
end
