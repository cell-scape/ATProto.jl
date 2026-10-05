# OAuth client: metadata, authorization URL, token exchange.
# Port of `packages/oauth/oauth-client/src/{oauth-client,validate-client-metadata}.ts`.

const FALLBACK_ALG = "ES256K"

"""
    OAuthClientMetadata(; kwargs...)

Validated OAuth client metadata (RFC 7591 + atproto spec).
Required: `client_id`, `redirect_uris`. Must include `"atproto"` scope,
`"code"` response type, and `"authorization_code"` grant type.
"""
struct OAuthClientMetadata
    client_id::String
    redirect_uris::Vector{String}
    client_name::Union{String,Nothing}
    client_uri::Union{String,Nothing}
    logo_uri::Union{String,Nothing}
    tos_uri::Union{String,Nothing}
    policy_uri::Union{String,Nothing}
    scope::String
    grant_types::Vector{String}
    response_types::Vector{String}
    token_endpoint_auth_method::String
    token_endpoint_auth_signing_alg::Union{String,Nothing}
    dpop_bound_access_tokens::Bool
    jwks::Union{Dict{String,Any},Nothing}

    function OAuthClientMetadata(; client_id, redirect_uris, client_name = nothing,
                                 client_uri = nothing, logo_uri = nothing,
                                 tos_uri = nothing, policy_uri = nothing,
                                 scope = "atproto", grant_types = ["authorization_code", "refresh_token"],
                                 response_types = ["code"],
                                 token_endpoint_auth_method = "none",
                                 token_endpoint_auth_signing_alg = nothing,
                                 dpop_bound_access_tokens = true,
                                 jwks = nothing)
        return new(String(client_id), String.(redirect_uris),
                   client_name === nothing ? nothing : String(client_name),
                   client_uri === nothing ? nothing : String(client_uri),
                   logo_uri === nothing ? nothing : String(logo_uri),
                   tos_uri === nothing ? nothing : String(tos_uri),
                   policy_uri === nothing ? nothing : String(policy_uri),
                   String(scope), String.(grant_types), String.(response_types),
                   String(token_endpoint_auth_method),
                   token_endpoint_auth_signing_alg === nothing ? nothing :
                   String(token_endpoint_auth_signing_alg),
                   Bool(dpop_bound_access_tokens), jwks)
    end
end

"""
    validate_client_metadata(meta) -> OAuthClientMetadata

Validate client metadata per the atproto OAuth spec:
- must include the `atproto` scope
- `response_types` must include `code`
- `grant_types` must include `authorization_code`
- `token_endpoint_auth_method` must be `none` or `private_key_jwt`
"""
function validate_client_metadata(meta::OAuthClientMetadata)
    scopes = split(meta.scope)
    "atproto" in scopes ||
        throw(ArgumentError("Client metadata must include the \"atproto\" scope"))
    "code" in meta.response_types ||
        throw(ArgumentError("\"response_types\" must include \"code\""))
    "authorization_code" in meta.grant_types ||
        throw(ArgumentError("\"grant_types\" must include \"authorization_code\""))
    meta.token_endpoint_auth_method in ("none", "private_key_jwt") ||
        throw(ArgumentError(
            "token_endpoint_auth_method must be \"none\" or \"private_key_jwt\", got $(meta.token_endpoint_auth_method)"))
    if meta.token_endpoint_auth_method == "none" && meta.token_endpoint_auth_signing_alg !== nothing
        throw(ArgumentError(
            "token_endpoint_auth_signing_alg must not be set when auth method is \"none\""))
    end
    if meta.token_endpoint_auth_method == "private_key_jwt" && meta.jwks === nothing
        throw(ArgumentError(
            "jwks required when token_endpoint_auth_method is \"private_key_jwt\""))
    end
    return meta
end

"Serialize client metadata to the JSON dict form for server registration."
function client_metadata_to_json(meta::OAuthClientMetadata)
    out = Dict{String,Any}(
        "client_id" => meta.client_id,
        "redirect_uris" => meta.redirect_uris,
        "scope" => meta.scope,
        "grant_types" => meta.grant_types,
        "response_types" => meta.response_types,
        "token_endpoint_auth_method" => meta.token_endpoint_auth_method,
        "dpop_bound_access_tokens" => meta.dpop_bound_access_tokens,
    )
    meta.client_name !== nothing && (out["client_name"] = meta.client_name)
    meta.client_uri !== nothing && (out["client_uri"] = meta.client_uri)
    meta.logo_uri !== nothing && (out["logo_uri"] = meta.logo_uri)
    meta.tos_uri !== nothing && (out["tos_uri"] = meta.tos_uri)
    meta.policy_uri !== nothing && (out["policy_uri"] = meta.policy_uri)
    meta.token_endpoint_auth_signing_alg !== nothing &&
        (out["token_endpoint_auth_signing_alg"] = meta.token_endpoint_auth_signing_alg)
    meta.jwks !== nothing && (out["jwks"] = meta.jwks)
    return out
end

"""
    build_authorization_url(authorization_endpoint, client_id, redirect_uri;
        code_challenge, code_challenge_method="S256", state, login_hint=nothing, scope="atproto")

Build the authorization URL the user should be redirected to.
"""
function build_authorization_url(authorization_endpoint::AbstractString,
                                 client_id::AbstractString,
                                 redirect_uri::AbstractString;
                                 code_challenge::AbstractString,
                                 code_challenge_method::AbstractString = "S256",
                                 state::AbstractString,
                                 login_hint::Union{AbstractString,Nothing} = nothing,
                                 scope::AbstractString = "atproto")::String
    params = ["client_id" => String(client_id),
              "redirect_uri" => String(redirect_uri),
              "response_type" => "code",
              "scope" => String(scope),
              "state" => String(state),
              "code_challenge" => String(code_challenge),
              "code_challenge_method" => String(code_challenge_method)]
    login_hint === nothing || push!(params, "login_hint" => String(login_hint))
    sep = occursin('?', authorization_endpoint) ? '&' : '?'
    query = string(join((HTTP.URIs.escapeuri(k) * "=" * HTTP.URIs.escapeuri(v) for (k, v) in params), "&"))
    return string(authorization_endpoint, sep, query)
end

"""
    exchange_code(token_endpoint, client_id, redirect_uri, code, verifier;
        dpop_key, fetch=default_fetch) -> Dict

Exchange an authorization code for tokens (RFC 6749 §4.1.3), DPoP-bound
when a `dpop_key` is provided.
"""
function exchange_code(token_endpoint::AbstractString,
                       client_id::AbstractString,
                       redirect_uri::AbstractString,
                       code::AbstractString,
                       code_verifier::AbstractString;
                       dpop_key = nothing,
                       fetch = XRPC.default_fetch)::Dict{String,Any}
    body = "grant_type=authorization_code" *
           "&code=" * HTTP.URIs.escapeuri(String(code)) *
           "&client_id=" * HTTP.URIs.escapeuri(String(client_id)) *
           "&redirect_uri=" * HTTP.URIs.escapeuri(String(redirect_uri)) *
           "&code_verifier=" * HTTP.URIs.escapeuri(String(code_verifier))
    headers = ["Content-Type" => "application/x-www-form-urlencoded",
               "Accept" => "application/json"]
    if dpop_key !== nothing
        proof = build_dpop_proof(dpop_key, "POST", token_endpoint)
        push!(headers, "DPoP" => proof)
    end
    res = fetch("POST", String(token_endpoint), headers, body)
    data = res.status == 200 ? JSON.parse(String(copy(res.body))) :
          throw(ErrorException("token exchange failed: HTTP $(res.status): $(String(copy(res.body)))"))
    return data
end

"""
    refresh_token(token_endpoint, client_id, refresh_jwt;
        dpop_key, fetch=default_fetch) -> Dict

Refresh an access token (RFC 6749 §6), DPoP-bound.
"""
function refresh_token(token_endpoint::AbstractString,
                       client_id::AbstractString,
                       refresh_jwt::AbstractString;
                       dpop_key = nothing,
                       fetch = XRPC.default_fetch)::Dict{String,Any}
    body = "grant_type=refresh_token" *
           "&refresh_token=" * HTTP.URIs.escapeuri(String(refresh_jwt)) *
           "&client_id=" * HTTP.URIs.escapeuri(String(client_id))
    headers = ["Content-Type" => "application/x-www-form-urlencoded",
               "Accept" => "application/json"]
    if dpop_key !== nothing
        proof = build_dpop_proof(dpop_key, "POST", token_endpoint)
        push!(headers, "DPoP" => proof)
    end
    res = fetch("POST", String(token_endpoint), headers, body)
    data = res.status == 200 ? JSON.parse(String(copy(res.body))) :
          throw(ErrorException("token refresh failed: HTTP $(res.status)"))
    return data
end
