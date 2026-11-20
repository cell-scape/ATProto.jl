module OAuth

using ..Crypto
using ..Syntax
using ..Identity
using ..PLC
using JSON
using HTTP
using Dates
using Random

_default_oauth_fetch(method::AbstractString, url::AbstractString, headers, body; timeout::Real = 30.0) =
    HTTP.request(String(method), String(url), headers, body === nothing ? UInt8[] : body;
                 status_exception = false, read_idle_timeout = Float64(timeout),
                 connect_timeout = Float64(timeout))

export OAuthClientMetadata,
    OAuthSession,
    ServiceAuthError,
    ServiceAuthClaims,
    validate_client_metadata,
    generate_pkce,
    generate_dpop_key,
    build_dpop_proof,
    discover_authorization_server,
    pushed_authorization_request,
    build_par_authorization_url,
    build_authorization_url,
    exchange_code,
    refresh_token,
    oauth_request,
    oauth_transport,
    create_service_jwt,
    verify_service_jwt,
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
include("service_auth.jl")

end # module
