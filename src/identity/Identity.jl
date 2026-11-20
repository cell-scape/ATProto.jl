module Identity

using HTTP
using JSON

using ..Syntax: ATProtoError, DID, Handle, did_method, did_identifier

include("errors.jl")
include("diddoc.jl")
include("resolver.jl")

export DEFAULT_PLC_URL, DEFAULT_DOH_URL,
       IdentityError,
       DIDVerificationMethod, DIDService, DIDDocument,
       parse_did_document, pds_endpoint, atproto_handle, signing_key,
       ResolvedIdentity, IdentityResolver, clear_cache!,
       did_web_url, resolve_did, resolve_handle, verify_handle, resolve_identity

end # module Identity
