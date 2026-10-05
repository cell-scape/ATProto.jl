module OAuth

using ..Crypto
using ..Syntax
using ..XRPC
using ..Identity
using ..DID
using JSON
using HTTP
using Dates
using Random

export OAuthClientMetadata,
    OAuthSession,
    validate_client_metadata,
    generate_pkce,
    generate_dpop_key,
    build_dpop_proof,
    build_authorization_url,
    exchange_code,
    refresh_token,
    oauth_request,
    sign_jwt_es256k,
    sign_jwt_es256,
    verify_jwt_es256k,
    verify_jwt_es256,
    jwt_decode,
    client_metadata_to_json,
    jwk_public_key,
    jwk_thumbprint

include("pkce.jl")
include("jwk.jl")
include("dpop.jl")
include("client.jl")
include("session.jl")

end # module
