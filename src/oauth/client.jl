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
_oauth_body_string(body::AbstractString) = String(body)
_oauth_body_string(body::AbstractVector{UInt8}) = String(copy(body))

function _oauth_response_header(response, name::AbstractString)::Union{String, Nothing}
    vals = HTTP.headers(response, name)
    isempty(vals) ? nothing : String(first(vals))
end

function _is_dpop_nonce_error(res)::Bool
    res.status in (400, 401) || return false
    nonce = _oauth_response_header(res, "DPoP-Nonce")
    isnothing(nonce) && return false
    body = _oauth_body_string(res.body)
    return occursin("use_dpop_nonce", body) || res.status == 401
end

"""
    discover_authorization_server(resource_url::AbstractString; fetch=_default_oauth_fetch) -> Dict{String, Any}

Discover the AT Protocol OAuth 2.1 Authorization Server metadata for a PDS or
resource server URL via RFC 9728 (`/.well-known/oauth-protected-resource`) and
RFC 8414 (`/.well-known/oauth-authorization-server`).
"""
function discover_authorization_server(
    resource_url::AbstractString;
    fetch = _default_oauth_fetch,
)::Dict{String, Any}
    base = rstrip(String(resource_url), '/')
    pr_url = base * "/.well-known/oauth-protected-resource"
    pr_res = fetch("GET", pr_url, ["Accept" => "application/json"], nothing)
    auth_issuer = if pr_res.status == 200
        pr_meta = JSON.parse(_oauth_body_string(pr_res.body), Dict{String, Any})
        servers = get(pr_meta, "authorization_servers", nothing)
        (servers isa AbstractVector && !isempty(servers)) ? rstrip(String(first(servers)), '/') : base
    else
        base
    end

    as_url = auth_issuer * "/.well-known/oauth-authorization-server"
    as_res = fetch("GET", as_url, ["Accept" => "application/json"], nothing)
    as_res.status == 200 ||
        throw(ErrorException("OAuth authorization server discovery failed at $as_url: HTTP $(as_res.status)"))
    return JSON.parse(_oauth_body_string(as_res.body), Dict{String, Any})
end

"""
    build_par_authorization_url(authorization_endpoint, client_id, request_uri) -> String

Build the user-facing authorization URL after a Pushed Authorization Request (PAR).
"""
function build_par_authorization_url(
    authorization_endpoint::AbstractString,
    client_id::AbstractString,
    request_uri::AbstractString,
)::String
    sep = occursin('?', authorization_endpoint) ? '&' : '?'
    return string(
        authorization_endpoint,
        sep,
        "client_id=", HTTP.URIs.escapeuri(String(client_id)),
        "&request_uri=", HTTP.URIs.escapeuri(String(request_uri)),
    )
end

"""
    pushed_authorization_request(par_endpoint, client_id, redirect_uri; code_challenge, state, code_challenge_method="S256", scope="atproto", login_hint=nothing, dpop_key=nothing, nonce=nothing, fetch=_default_oauth_fetch) -> Dict{String, Any}

Submit an OAuth 2.1 Pushed Authorization Request (PAR, RFC 9126) with PKCE and
optional DPoP proof (automatically retrying once if the server issues a
`DPoP-Nonce` challenge). Returns the parsed JSON response containing
`"request_uri"` and `"expires_in"`.
"""
function pushed_authorization_request(
    par_endpoint::AbstractString,
    client_id::AbstractString,
    redirect_uri::AbstractString;
    code_challenge::AbstractString,
    state::AbstractString,
    code_challenge_method::AbstractString = "S256",
    scope::AbstractString = "atproto",
    login_hint::Union{AbstractString, Nothing} = nothing,
    dpop_key = nothing,
    nonce::Union{AbstractString, Nothing} = nothing,
    fetch = _default_oauth_fetch,
)::Dict{String, Any}
    params = [
        "client_id" => String(client_id),
        "redirect_uri" => String(redirect_uri),
        "response_type" => "code",
        "scope" => String(scope),
        "state" => String(state),
        "code_challenge" => String(code_challenge),
        "code_challenge_method" => String(code_challenge_method),
    ]
    login_hint === nothing || push!(params, "login_hint" => String(login_hint))
    body = join((HTTP.URIs.escapeuri(k) * "=" * HTTP.URIs.escapeuri(v) for (k, v) in params), "&")

    function _do_par(use_nonce)
        headers = Pair{String, String}[
            "Content-Type" => "application/x-www-form-urlencoded",
            "Accept" => "application/json",
        ]
        if dpop_key !== nothing
            proof = build_dpop_proof(dpop_key, "POST", par_endpoint; nonce = use_nonce)
            push!(headers, "DPoP" => proof)
        end
        return fetch("POST", String(par_endpoint), headers, body)
    end

    res = _do_par(nonce)
    if dpop_key !== nothing && _is_dpop_nonce_error(res)
        fresh = _oauth_response_header(res, "DPoP-Nonce")
        isnothing(fresh) || (res = _do_par(fresh))
    end
    res.status in (200, 201) ||
        throw(ErrorException("PAR request failed: HTTP $(res.status): $(_oauth_body_string(res.body))"))
    return JSON.parse(_oauth_body_string(res.body), Dict{String, Any})
end

function exchange_code(token_endpoint::AbstractString,
                       client_id::AbstractString,
                       redirect_uri::AbstractString,
                       code::AbstractString,
                       code_verifier::AbstractString;
                       dpop_key = nothing,
                       nonce::Union{AbstractString, Nothing} = nothing,
                       fetch = _default_oauth_fetch)::Dict{String,Any}
    body = "grant_type=authorization_code" *
           "&code=" * HTTP.URIs.escapeuri(String(code)) *
           "&client_id=" * HTTP.URIs.escapeuri(String(client_id)) *
           "&redirect_uri=" * HTTP.URIs.escapeuri(String(redirect_uri)) *
           "&code_verifier=" * HTTP.URIs.escapeuri(String(code_verifier))
    function _do_exchange(use_nonce)
        headers = Pair{String, String}[
            "Content-Type" => "application/x-www-form-urlencoded",
            "Accept" => "application/json",
        ]
        if dpop_key !== nothing
            proof = build_dpop_proof(dpop_key, "POST", token_endpoint; nonce = use_nonce)
            push!(headers, "DPoP" => proof)
        end
        return fetch("POST", String(token_endpoint), headers, body)
    end
    res = _do_exchange(nonce)
    if dpop_key !== nothing && _is_dpop_nonce_error(res)
        fresh = _oauth_response_header(res, "DPoP-Nonce")
        isnothing(fresh) || (res = _do_exchange(fresh))
    end
    data = res.status == 200 ? JSON.parse(_oauth_body_string(res.body), Dict{String, Any}) :
          throw(ErrorException("token exchange failed: HTTP $(res.status): $(_oauth_body_string(res.body))"))
    return data
end

"""
    refresh_token(token_endpoint, client_id, refresh_jwt;
        dpop_key=nothing, nonce=nothing, fetch=_default_oauth_fetch) -> Dict

Refresh an access token (RFC 6749 §6), DPoP-bound with automatic `DPoP-Nonce` retry.
"""
function refresh_token(token_endpoint::AbstractString,
                       client_id::AbstractString,
                       refresh_jwt::AbstractString;
                       dpop_key = nothing,
                       nonce::Union{AbstractString, Nothing} = nothing,
                       fetch = _default_oauth_fetch)::Dict{String,Any}
    body = "grant_type=refresh_token" *
           "&refresh_token=" * HTTP.URIs.escapeuri(String(refresh_jwt)) *
           "&client_id=" * HTTP.URIs.escapeuri(String(client_id))
    function _do_refresh(use_nonce)
        headers = Pair{String, String}[
            "Content-Type" => "application/x-www-form-urlencoded",
            "Accept" => "application/json",
        ]
        if dpop_key !== nothing
            proof = build_dpop_proof(dpop_key, "POST", token_endpoint; nonce = use_nonce)
            push!(headers, "DPoP" => proof)
        end
        return fetch("POST", String(token_endpoint), headers, body)
    end
    res = _do_refresh(nonce)
    if dpop_key !== nothing && _is_dpop_nonce_error(res)
        fresh = _oauth_response_header(res, "DPoP-Nonce")
        isnothing(fresh) || (res = _do_refresh(fresh))
    end
    data = res.status == 200 ? JSON.parse(_oauth_body_string(res.body), Dict{String, Any}) :
          throw(ErrorException("token refresh failed: HTTP $(res.status)"))
    return data
end
