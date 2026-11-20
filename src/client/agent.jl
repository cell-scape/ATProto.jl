#= client/agent.jl =#

"""
    DEFAULT_SERVICE

Default AT Protocol entry service URL (`"https://bsky.social"`).
"""
const DEFAULT_SERVICE = "https://bsky.social"

"""
    PUBLIC_APPVIEW

Unauthenticated public Bluesky AppView URL (`"https://public.api.bsky.app"`).
"""
const PUBLIC_APPVIEW = "https://public.api.bsky.app"

function _default_transport(
    method::String,
    url::String,
    headers::Vector{Pair{String, String}},
    body::Union{Vector{UInt8}, String, Nothing};
    timeout::Real = 30.0,
)
    req_body = isnothing(body) ? UInt8[] : body
    return HTTP.request(
        method,
        url,
        headers,
        req_body;
        status_exception = false,
        readtimeout = Int(ceil(timeout)),
        connect_timeout = Int(ceil(timeout)),
    )
end

mutable struct _AgentState
    lock::ReentrantLock
    session::Union{Session, Nothing}
    pds_url::Union{String, Nothing}
    rate_limit::Union{RateLimitInfo, Nothing}
    on_session_change::Any
end

"""
    AtpAgent(service=DEFAULT_SERVICE; kwargs...)

AT Protocol XRPC client managing service/PDS routing, JWT sessions, automatic
single-flight token refresh on `ExpiredToken`, rate-limit tracking, and optional
`atproto-proxy` / `atproto-accept-labelers` headers.

# Keyword Arguments
- `auto_pds::Bool = true`: Automatically route authenticated requests to the user's
  PDS endpoint from `didDoc` when returned by `createSession` / `refreshSession`.
- `proxy::Union{AbstractString, Nothing} = nothing`: Optional `atproto-proxy` header value
  (e.g. `"did:web:api.bsky.chat#bsky_chat"`).
- `labelers::Vector{String} = String[]`: Optional `atproto-accept-labelers` DID list.
- `timeout::Float64 = 30.0`: HTTP request timeout in seconds.
- `on_session_change = nothing`: Optional callback `(event::Symbol, session::Union{Session, Nothing}) -> nothing`
  invoked on `:create`, `:refresh`, `:resume`, `:expired`, and `:delete`.
- `transport = _default_transport`: Pluggable HTTP transport function `(method, url, headers, body; timeout) -> HTTP.Response`
  (useful for mocking in tests or custom HTTP middleware).
"""
struct AtpAgent
    service::String
    auto_pds::Bool
    proxy::Union{String, Nothing}
    labelers::Vector{String}
    timeout::Float64
    transport::Any
    state::_AgentState
end

function AtpAgent(
    service::AbstractString = DEFAULT_SERVICE;
    auto_pds::Bool = true,
    proxy::Union{AbstractString, Nothing} = nothing,
    labelers::AbstractVector{<:AbstractString} = String[],
    timeout::Real = 30.0,
    on_session_change = nothing,
    transport = _default_transport,
)
    clean_service = String(rstrip(service, '/'))
    state = _AgentState(ReentrantLock(), nothing, nothing, nothing, on_session_change)
    return AtpAgent(
        clean_service,
        auto_pds,
        isnothing(proxy) ? nothing : String(proxy),
        String[String(l) for l in labelers],
        Float64(timeout),
        transport,
        state,
    )
end

"""
    service_url(agent::AtpAgent) -> String

Return the active base URL for XRPC requests (the resolved PDS endpoint when
authenticated and `auto_pds=true`, otherwise `agent.service`).
"""
function service_url(agent::AtpAgent)
    return lock(agent.state.lock) do
        (agent.auto_pds && !isnothing(agent.state.pds_url)) ? agent.state.pds_url : agent.service
    end
end

"""
    session(agent::AtpAgent) -> Union{Session, Nothing}

Return the current [`Session`](@ref) snapshot, or `nothing` if unauthenticated.
"""
session(agent::AtpAgent) = lock(() -> agent.state.session, agent.state.lock)

"""
    is_authenticated(agent::AtpAgent) -> Bool

Return `true` if `agent` currently holds an active session.
"""
is_authenticated(agent::AtpAgent) = !isnothing(session(agent))

"""
    rate_limit(agent::AtpAgent) -> Union{RateLimitInfo, Nothing}

Return the most recently observed [`RateLimitInfo`](@ref) from server response headers.
"""
rate_limit(agent::AtpAgent) = lock(() -> agent.state.rate_limit, agent.state.lock)

"""
    with_proxy(agent::AtpAgent, proxy::Union{AbstractString, Nothing}) -> AtpAgent

Return a lightweight view of `agent` with the `atproto-proxy` header set to `proxy`
(for example `"did:web:api.bsky.chat#bsky_chat"`), sharing the same underlying session
and refresh lock.
"""
function with_proxy(agent::AtpAgent, proxy::Union{AbstractString, Nothing})
    return AtpAgent(
        agent.service,
        agent.auto_pds,
        isnothing(proxy) ? nothing : String(proxy),
        copy(agent.labelers),
        agent.timeout,
        agent.transport,
        agent.state,
    )
end

"""
    with_labelers(agent::AtpAgent, labelers::AbstractVector{<:AbstractString}) -> AtpAgent

Return a lightweight view of `agent` sending `atproto-accept-labelers` headers,
sharing the same underlying session and refresh lock.
"""
function with_labelers(agent::AtpAgent, labelers::AbstractVector{<:AbstractString})
    return AtpAgent(
        agent.service,
        agent.auto_pds,
        agent.proxy,
        String[String(l) for l in labelers],
        agent.timeout,
        agent.transport,
        agent.state,
    )
end

function Base.show(io::IO, a::AtpAgent)
    s = session(a)
    print(io, "AtpAgent(service=", repr(service_url(a)))
    if isnothing(s)
        print(io, ", authenticated=false")
    else
        print(io, ", handle=", repr(String(s.handle)), ", did=", repr(String(s.did)))
    end
    if !isnothing(a.proxy)
        print(io, ", proxy=", repr(a.proxy))
    end
    print(io, ")")
end

function _notify_session(agent::AtpAgent, event::Symbol, s::Union{Session, Nothing})
    cb = agent.state.on_session_change
    isnothing(cb) || cb(event, s)
    return nothing
end

function _update_session!(agent::AtpAgent, s::Union{Session, Nothing}, event::Symbol)
    lock(agent.state.lock) do
        agent.state.session = s
        if isnothing(s)
            agent.state.pds_url = nothing
        else
            pds = _extract_pds_endpoint(s.did_doc)
            !isnothing(pds) && (agent.state.pds_url = pds)
        end
    end
    _notify_session(agent, event, s)
    return s
end

function _build_headers(
    agent::AtpAgent;
    auth_mode::Symbol = :access,
    content_type::Union{String, Nothing} = nothing,
    extra_headers::AbstractVector{Pair{String, String}} = Pair{String, String}[],
)
    hdrs = Pair{String, String}[]
    s = session(agent)

    if auth_mode == :access && !isnothing(s)
        push!(hdrs, "Authorization" => "Bearer " * s.access_jwt)
    elseif auth_mode == :refresh
        isnothing(s) && throw(AuthError("Cannot use refresh token: agent is not authenticated"))
        push!(hdrs, "Authorization" => "Bearer " * s.refresh_jwt)
    end

    if !isnothing(content_type)
        push!(hdrs, "Content-Type" => content_type)
    end
    if !isnothing(agent.proxy)
        push!(hdrs, "atproto-proxy" => agent.proxy)
    end
    if !isempty(agent.labelers)
        push!(hdrs, "atproto-accept-labelers" => join(agent.labelers, ", "))
    end
    for kv in extra_headers
        push!(hdrs, kv)
    end

    return hdrs
end

function _raw_request(
    agent::AtpAgent,
    method::String,
    nsid::NSID;
    query_string::String = "",
    body::Union{Vector{UInt8}, String, Nothing} = nothing,
    content_type::Union{String, Nothing} = nothing,
    auth_mode::Symbol = :access,
    extra_headers::AbstractVector{Pair{String, String}} = Pair{String, String}[],
    base_url::Union{String, Nothing} = nothing,
)
    root = isnothing(base_url) ? service_url(agent) : base_url
    url = isempty(query_string) ?
        string(root, "/xrpc/", nsid) :
        string(root, "/xrpc/", nsid, "?", query_string)
    hdrs = _build_headers(agent; auth_mode, content_type, extra_headers)
    resp = agent.transport(method, url, hdrs, body; timeout = agent.timeout)

    rl = _parse_rate_limit(resp)
    if !isnothing(rl)
        lock(agent.state.lock) do
            agent.state.rate_limit = rl
        end
    end

    if 200 <= resp.status < 300
        return resp
    end
    throw(_parse_xrpc_error(resp))
end

"""
Single-flight token refresh: if multiple tasks concurrently fail with `ExpiredToken`
using the same `failed_access_jwt`, only the first task calls `refreshSession`
(preventing single-use refresh JWT invalidation); subsequent tasks reuse the
newly refreshed session.
"""
function _refresh_if_stale!(agent::AtpAgent, failed_access_jwt::String)
    result = lock(agent.state.lock) do
        cur = agent.state.session
        isnothing(cur) && return (nothing, false)
        # Another task already refreshed while we were waiting on the lock.
        cur.access_jwt != failed_access_jwt && return (cur, false)

        try
            resp = _raw_request(
                agent,
                "POST",
                NSID("com.atproto.server.refreshSession");
                auth_mode = :refresh,
            )
            out = JSON.parse(String(copy(resp.body)), ComAtprotoServerRefreshSessionOutput)
            updated = _session_from_output(out; prev = cur)
            agent.state.session = updated
            pds = _extract_pds_endpoint(updated.did_doc)
            !isnothing(pds) && (agent.state.pds_url = pds)
            return (updated, true)
        catch e
            agent.state.session = nothing
            agent.state.pds_url = nothing
            return (e, true)
        end
    end

    val, did_refresh = result
    if val isa Exception
        _notify_session(agent, :expired, nothing)
        throw(val)
    elseif val isa Session
        did_refresh && _notify_session(agent, :refresh, val)
        return val
    end
    return nothing
end

function _xrpc_request(
    agent::AtpAgent,
    method::String,
    nsid::NSID;
    query_string::String = "",
    body::Union{Vector{UInt8}, String, Nothing} = nothing,
    content_type::Union{String, Nothing} = nothing,
    auth_mode::Symbol = :access,
    extra_headers::AbstractVector{Pair{String, String}} = Pair{String, String}[],
    base_url::Union{String, Nothing} = nothing,
    allow_refresh::Bool = true,
)
    used_jwt = begin
        s = session(agent)
        (auth_mode == :access && !isnothing(s)) ? s.access_jwt : nothing
    end

    try
        return _raw_request(
            agent,
            method,
            nsid;
            query_string,
            body,
            content_type,
            auth_mode,
            extra_headers,
            base_url,
        )
    catch e
        if allow_refresh && e isa XRPCError && _is_expired_token_error(e) && !isnothing(used_jwt)
            _refresh_if_stale!(agent, used_jwt)
            return _raw_request(
                agent,
                method,
                nsid;
                query_string,
                body,
                content_type,
                auth_mode,
                extra_headers,
                base_url,
            )
        end
        rethrow()
    end
end

"""
    login!(agent::AtpAgent, identifier::AbstractString, password::AbstractString; auth_factor_token=nothing) -> Session

Authenticate with `com.atproto.server.createSession` using a handle/DID/email and
app password. Stores the resulting [`Session`](@ref) on `agent` and routes future
requests to the user's PDS if present in `didDoc`.
"""
function login!(
    agent::AtpAgent,
    identifier::AbstractString,
    password::AbstractString;
    auth_factor_token::Union{AbstractString, Nothing} = nothing,
)
    input = ComAtprotoServerCreateSessionInput(
        identifier = String(identifier),
        password = String(password),
        authFactorToken = isnothing(auth_factor_token) ? nothing : String(auth_factor_token),
    )
    resp = _raw_request(
        agent,
        "POST",
        NSID("com.atproto.server.createSession");
        body = JSON.json(input),
        content_type = "application/json",
        auth_mode = :none,
        base_url = agent.service,
    )
    out = JSON.parse(String(copy(resp.body)), ComAtprotoServerCreateSessionOutput)
    s = _session_from_output(out)
    return _update_session!(agent, s, :create)
end

"""
    refresh_session!(agent::AtpAgent) -> Session

Explicitly refresh the current session via `com.atproto.server.refreshSession`
using the stored `refresh_jwt`.
"""
function refresh_session!(agent::AtpAgent)
    cur = session(agent)
    isnothing(cur) && throw(AuthError("Cannot refresh session: agent is not authenticated"))
    return _refresh_if_stale!(agent, cur.access_jwt)
end

"""
    resume_session!(agent::AtpAgent, s::Session; verify::Bool=true) -> Session

Restore a previously persisted [`Session`](@ref) onto `agent`. When `verify=true`
(the default), verifies the session with `com.atproto.server.getSession` (automatically
refreshing via `refresh_jwt` if the access token has expired).
"""
function resume_session!(agent::AtpAgent, s::Session; verify::Bool = true)
    _update_session!(agent, s, :resume)
    if verify
        resp = _xrpc_request(agent, "GET", NSID("com.atproto.server.getSession"))
        info = JSON.parse(String(copy(resp.body)), ComAtprotoServerGetSessionOutput)
        cur = session(agent)
        merged = Session(
            info.did,
            info.handle,
            cur.access_jwt,
            cur.refresh_jwt,
            isnothing(info.email) ? cur.email : info.email,
            isnothing(info.active) ? cur.active : info.active,
            isnothing(info.status) ? cur.status : info.status,
            isnothing(info.didDoc) ? cur.did_doc : info.didDoc,
        )
        return _update_session!(agent, merged, :resume)
    end
    return s
end

"""
    logout!(agent::AtpAgent; remote::Bool=true) -> Nothing

Clear the session from `agent`. When `remote=true` (the default) and authenticated,
revokes the session on the server via `com.atproto.server.deleteSession`.
"""
function logout!(agent::AtpAgent; remote::Bool = true)
    if remote && is_authenticated(agent)
        try
            _raw_request(
                agent,
                "POST",
                NSID("com.atproto.server.deleteSession");
                auth_mode = :refresh,
            )
        finally
            _update_session!(agent, nothing, :delete)
        end
    else
        _update_session!(agent, nothing, :delete)
    end
    return nothing
end
