# Authenticated sessions with automatic refresh. Port of the session handling
# from @atproto/api's agent (refresh on 401, retry once).

"""
    AuthSession

Mutable session state from `com.atproto.server.createSession`: DID, handle,
and the current access/refresh JWTs.
"""
mutable struct AuthSession
    did::String
    handle::String
    access_jwt::String
    refresh_jwt::String
end

const CREATE_SESSION_NSID = "com.atproto.server.createSession"
const REFRESH_SESSION_NSID = "com.atproto.server.refreshSession"

"""
    create_session(client, identifier, password) -> AuthSession

Log in (`com.atproto.server.createSession`) and return the session.
"""
function create_session(client::XRPCClient, identifier::AbstractString,
                        password::AbstractString)::AuthSession
    res = xrpc_call(client, CREATE_SESSION_NSID;
        method = :post,
        data = Dict{String,Any}("identifier" => String(identifier),
                                "password" => String(password)),
        encoding = "application/json")
    data = res.data
    data isa AbstractDict || throw(XRPCError(2, nothing, "invalid createSession response"))
    for field in ("did", "handle", "accessJwt", "refreshJwt")
        haskey(data, field) && data[field] isa AbstractString ||
            throw(XRPCError(2, nothing, "invalid createSession response: missing $field"))
    end
    return AuthSession(data["did"], data["handle"], data["accessJwt"], data["refreshJwt"])
end

"""
    refresh_session!(client, session) -> AuthSession

Refresh `session` in place via `com.atproto.server.refreshSession`
(using the refresh JWT).
"""
function refresh_session!(client::XRPCClient, session::AuthSession)::AuthSession
    res = xrpc_call(client, REFRESH_SESSION_NSID;
        method = :post,
        headers = ["Authorization" => "Bearer " * session.refresh_jwt])
    data = res.data
    data isa AbstractDict || throw(XRPCError(2, nothing, "invalid refreshSession response"))
    haskey(data, "accessJwt") && data["accessJwt"] isa AbstractString ||
        throw(XRPCError(2, nothing, "invalid refreshSession response: missing accessJwt"))
    session.access_jwt = data["accessJwt"]
    if haskey(data, "refreshJwt") && data["refreshJwt"] isa AbstractString
        session.refresh_jwt = data["refreshJwt"]
    end
    if haskey(data, "did") && data["did"] isa AbstractString
        session.did = data["did"]
    end
    if haskey(data, "handle") && data["handle"] isa AbstractString
        session.handle = data["handle"]
    end
    return session
end

"Authorization headers carrying the current access token."
session_headers(session::AuthSession) = ["Authorization" => "Bearer " * session.access_jwt]

"""
    SessionClient(; service, session=nothing, fetch, timeout, headers)

An authenticated XRPC client: wraps an [`XRPCClient`](@ref) plus an
[`AuthSession`](@ref). Calls carry `Authorization` automatically; a 401
triggers one token refresh and a single retry.
"""
struct SessionClient{F}
    client::XRPCClient{F}
    session::AuthSession
end

SessionClient(client::XRPCClient; session::AuthSession) = SessionClient(client, session)
SessionClient(; service::AbstractString, session::AuthSession, kwargs...) =
    SessionClient(XRPCClient(; service = service, kwargs...), session)

"""
    xrpc_call(sc, nsid; kwargs...) -> XRPCResponse

Like [`xrpc_call`](@ref) on the underlying client, but authenticated; on a
401 the session is refreshed and the call retried once.
"""
function xrpc_call(sc::SessionClient, nsid::AbstractString; kwargs...)::XRPCResponse
    headers = get(kwargs, :headers, ())
    merged = vcat(Pair{String,String}[String(k) => String(v) for (k, v) in headers],
                  session_headers(sc.session))
    try
        return xrpc_call(sc.client, nsid; kwargs..., headers = merged)
    catch err
        if err isa XRPCError && err.status == 401
            refresh_session!(sc.client, sc.session)
            merged = vcat(Pair{String,String}[String(k) => String(v) for (k, v) in headers],
                          session_headers(sc.session))
            return xrpc_call(sc.client, nsid; kwargs..., headers = merged)
        end
        rethrow()
    end
end

xrpc_get(sc::SessionClient, nsid::AbstractString; params = Dict{String,Any}(), kwargs...) =
    xrpc_call(sc, nsid; method = :get, params, kwargs...)

xrpc_proc(sc::SessionClient, nsid::AbstractString;
          data = nothing, encoding::Union{AbstractString,Nothing} = nothing,
          params = Dict{String,Any}(), kwargs...) =
    xrpc_call(sc, nsid; method = :post, params, data, encoding, kwargs...)
