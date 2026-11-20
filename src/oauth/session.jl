# OAuth session: DPoP-bound authenticated requests with token refresh.

"""
    OAuthSession

An authenticated OAuth session: tokens + DPoP key + server metadata. Makes
DPoP-bound requests to resource servers (PDS) and refreshes tokens on 401.
"""
mutable struct OAuthSession
    client_id::String
    token_endpoint::String
    dpop_key::Union{P256Key,Secp256k1Key}
    access_token::String
    refresh_token::Union{String,Nothing}
    did::Union{String,Nothing}
    fetch
end

function OAuthSession(; client_id, token_endpoint, dpop_key, access_token,
                      refresh_token = nothing, did = nothing,
                      fetch = _default_oauth_fetch)
    return OAuthSession(String(client_id), String(token_endpoint), dpop_key,
                        String(access_token),
                        refresh_token === nothing ? nothing : String(refresh_token),
                        did === nothing ? nothing : String(did), fetch)
end

"""
    oauth_request(session, method, url, body=nothing; headers=[]) -> HTTP.Response

Make a DPoP-bound request with the session's access token. On 401 with an
`use_dpop_nonce` error, retries with the fresh nonce. On `invalid_token`,
refreshes and retries.
"""
function oauth_request(session::OAuthSession, method::AbstractString,
                       url::AbstractString, body = nothing;
                       headers = Pair{String,String}[])
    res = _dpop_request(session, method, url, body, headers)
    if res.status == 401
        # try with fresh nonce if the server sent one
        nonce = _response_header(res, "DPoP-Nonce")
        if nonce !== nothing
            res = _dpop_request(session, method, url, body, headers; nonce = nonce)
        end
        # try token refresh if still unauthorized
        if res.status == 401 && session.refresh_token !== nothing
            _refresh!(session)
            res = _dpop_request(session, method, url, body, headers; nonce = nonce)
        end
    end
    return res
end

function _dpop_request(session::OAuthSession, method::AbstractString,
                       url::AbstractString, body, headers;
                       nonce::Union{AbstractString,Nothing} = nothing)
    proof = build_dpop_proof(session.dpop_key, method, url;
                             nonce = nonce,
                             access_token = session.access_token)
    all_headers = Pair{String,String}[
        "Authorization" => "DPoP " * session.access_token,
        "DPoP" => proof,
        headers...,
    ]
    body === nothing || push!(all_headers, "Content-Type" => "application/json")
    return session.fetch(String(method), String(url), all_headers, body)
end

function _refresh!(session::OAuthSession)
    local rt::String = something(session.refresh_token)
    data = refresh_token(session.token_endpoint, session.client_id,
                         rt; dpop_key = session.dpop_key,
                         fetch = session.fetch)
    session.access_token = String(data["access_token"])
    haskey(data, "refresh_token") &&
        (session.refresh_token = String(data["refresh_token"]))
    return session
end

function _response_header(response, name)
    vals = HTTP.headers(response, name)
    isempty(vals) ? nothing : String(first(vals))
end

"""
    oauth_transport(session::OAuthSession) -> Function

Return an `AtpAgent`-compatible HTTP transport closure `(method, url, headers, body; timeout)`
that signs every outgoing request with DPoP proof tokens via [`oauth_request`](@ref),
handling `DPoP-Nonce` retries and OAuth token refresh automatically.

Pass it to `AtpAgent(pds_url; transport = oauth_transport(oauth_session))` (or use
`AtpAgent(oauth_session, pds_url)`) to call any `xrpc` endpoint with OAuth 2.1.
"""
function oauth_transport(session::OAuthSession)
    return function (method::String, url::String, headers::Vector{Pair{String, String}},
                     body::Union{Vector{UInt8}, String, Nothing}; timeout::Real = 30.0)
        # Strip any Bearer Authorization header so DPoP auth takes precedence
        fwd = Pair{String, String}[
            k => v for (k, v) in headers if lowercase(k) != "authorization"
        ]
        # Avoid duplicate Content-Type if already provided in headers
        has_ct = any(lowercase(k) == "content-type" for (k, _) in fwd)
        return _oauth_request_with_ct(session, method, url, body, fwd, has_ct)
    end
end

function _oauth_request_with_ct(
    session::OAuthSession,
    method::AbstractString,
    url::AbstractString,
    body,
    headers::Vector{Pair{String, String}},
    has_ct::Bool,
)
    function _send(nonce)
        proof = build_dpop_proof(session.dpop_key, method, url;
                                 nonce = nonce,
                                 access_token = session.access_token)
        all_headers = Pair{String, String}[
            "Authorization" => "DPoP " * session.access_token,
            "DPoP" => proof,
            headers...,
        ]
        if body !== nothing && !has_ct
            push!(all_headers, "Content-Type" => "application/json")
        end
        return session.fetch(String(method), String(url), all_headers, body)
    end

    res = _send(nothing)
    if res.status == 401
        nonce = _response_header(res, "DPoP-Nonce")
        if nonce !== nothing
            res = _send(nonce)
        end
        if res.status == 401 && session.refresh_token !== nothing
            _refresh!(session)
            res = _send(nonce)
        end
    end
    return res
end
