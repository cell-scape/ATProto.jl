# Agents: authenticated/unauthenticated entry points + record conveniences.

"""
    Agent(; service, fetch=XRPC.default_fetch, timeout=30, headers=[])

An unauthenticated atproto client bound to a service (usually a PDS, e.g.
`"https://bsky.social"`). Call the generated namespaces with it, or upgrade
to a [`SessionAgent`](@ref) via [`login`](@ref).
"""
struct Agent{F}
    client::XRPCClient{F}
end

Agent(; service::AbstractString, kwargs...) = Agent(XRPCClient(; service, kwargs...))

"""
    SessionAgent(agent_or_service, identifier, password; kwargs...) -> SessionAgent
    login(x, identifier, password) -> SessionAgent

Log in via `com.atproto.server.createSession` and return an authenticated
agent whose calls carry the access token and auto-refresh on 401.
"""
struct SessionAgent{F}
    client::SessionClient{F}
    did::String
    handle::String
end

function SessionAgent(x::Agent, identifier::AbstractString, password::AbstractString)
    session = create_session(x.client, identifier, password)
    sc = SessionClient(x.client; session)
    return SessionAgent(sc, session.did, session.handle)
end

SessionAgent(service::AbstractString, identifier::AbstractString,
             password::AbstractString; kwargs...) =
    SessionAgent(Agent(; service, kwargs...), identifier, password)

login(x, identifier::AbstractString, password::AbstractString) =
    SessionAgent(x, identifier, password)

"The underlying XRPC client of an Agent, SessionAgent, or raw client."
client_of(agent::Agent) = agent.client
client_of(agent::SessionAgent) = agent.client
client_of(client::XRPCClient) = client
client_of(client::SessionClient) = client

"The service base URL behind anything client-like."
service_url(x) = x isa AbstractString ? String(x) :
                 (c = client_of(x); c isa SessionClient ? c.client.service : c.service)

"The current session (access/refresh JWTs)."
session_of(agent::SessionAgent) = agent.client.session

"The authenticated DID."
did_of(agent::SessionAgent) = agent.did

"The authenticated handle."
handle_of(agent::SessionAgent) = agent.handle

"""
    resolve_handle(agent, handle) -> String

Resolve a handle to a DID server-side (`com.atproto.identity.resolveHandle`).
For local resolution (DNS/well-known), use `ATProto.Identity`.
"""
function resolve_handle(agent, handle::AbstractString)::String
    res = _call_query(client_of(agent), "com.atproto.identity.resolveHandle";
                      handle = handle)
    did = get(res, "did", nothing)
    did isa AbstractString || throw(ErrorException("resolveHandle returned no did"))
    return String(did)
end

"""
    upload_blob(agent, bytes, mime_type) -> BlobRef

Upload a blob (`com.atproto.repo.uploadBlob`) and return the assigned
[`BlobRef`](@ref).
"""
function upload_blob(agent, bytes::AbstractVector{UInt8}, mime_type::AbstractString)
    res = _call_proc(client_of(agent), "com.atproto.repo.uploadBlob";
                     data = bytes, encoding = String(mime_type))
    blob = get(res, "blob", nothing)
    blob isa BlobRef && return blob  # already converted by _blobify
    blob isa AbstractDict || throw(ErrorException("uploadBlob returned no blob"))
    br = blob_ref_from_json(blob)
    br === nothing && throw(ErrorException("uploadBlob returned an invalid blob ref"))
    return br
end

"""
    put_record(agent, did, collection, rkey, record) -> Dict

Write a record at a specific key (`com.atproto.repo.putRecord`).
"""
function put_record(agent, did::AbstractString, collection::AbstractString,
                    rkey::AbstractString, record::AbstractDict)
    return _call_proc(client_of(agent), "com.atproto.repo.putRecord";
        repo = String(did), collection = String(collection),
        rkey = String(rkey),
        data = Dict{String,Any}("repo" => String(did),
                                "collection" => String(collection),
                                "rkey" => String(rkey),
                                "record" => record),
    )
end

"""
    create_record(agent, did, collection, record; rkey=TID()) -> Dict

Create a record with a fresh TID key (`com.atproto.repo.createRecord`).
"""
function create_record(agent, did::AbstractString, collection::AbstractString,
                       record::AbstractDict; rkey = TID())
    return _call_proc(client_of(agent), "com.atproto.repo.createRecord";
        data = Dict{String,Any}("repo" => String(did),
                                "collection" => String(collection),
                                "rkey" => string(rkey),
                                "record" => record),
    )
end

"""
    get_record(agent, did, collection, rkey) -> Dict

Fetch a record (`com.atproto.repo.getRecord`).
"""
function get_record(agent, did::AbstractString, collection::AbstractString,
                    rkey::AbstractString)
    return _call_query(client_of(agent), "com.atproto.repo.getRecord";
        repo = String(did), collection = String(collection), rkey = String(rkey))
end

"""
    delete_record(agent, did, collection, rkey) -> Dict

Delete a record (`com.atproto.repo.deleteRecord`).
"""
function delete_record(agent, did::AbstractString, collection::AbstractString,
                       rkey::AbstractString)
    return _call_proc(client_of(agent), "com.atproto.repo.deleteRecord";
        data = Dict{String,Any}("repo" => String(did),
                                "collection" => String(collection),
                                "rkey" => String(rkey)),
    )
end

"""
    create_post(agent, text; langs=["en"], reply=nothing, embed=nothing) -> Dict

Create an `app.bsky.feed.post` record for the authenticated user with a
fresh timestamp.
"""
function create_post(agent::SessionAgent, text::AbstractString;
                     langs = ["en"], reply = nothing, embed = nothing,
                     facets = nothing)
    record = Dict{String,Any}(
        "\$type" => "app.bsky.feed.post",
        "text" => String(text),
        "createdAt" => datetime_string(Dates.now(Dates.UTC)),
    )
    isempty(langs) || (record["langs"] = String[String(l) for l in langs])
    reply === nothing || (record["reply"] = reply)
    embed === nothing || (record["embed"] = embed)
    facets === nothing || (record["facets"] = facets)
    return create_record(agent, agent.did, "app.bsky.feed.post", record)
end

"""
    delete_post(agent, rkey)

Delete the authenticated user's post by record key.
"""
delete_post(agent::SessionAgent, rkey::AbstractString) =
    delete_record(agent, agent.did, "app.bsky.feed.post", rkey)
