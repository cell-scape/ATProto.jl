#= client/helpers.jl — High-level ergonomic wrappers over common ATProto / Bluesky endpoints =#

function _default_repo(agent::AtpAgent, repo)
    !isnothing(repo) && return string(repo)
    s = session(agent)
    isnothing(s) && throw(AuthError("`repo` must be provided when agent is not authenticated"))
    return String(s.did)
end

"""
    get_profile(agent::AtpAgent, actor) -> AppBskyActorDefsProfileViewDetailed

Fetch detailed profile information for `actor` (a `Handle`, `DID`, or string).
"""
get_profile(agent::AtpAgent, actor::Union{Handle, DID, AbstractString}) =
    xrpc(agent, API.App.Bsky.Actor.GetProfile; actor = string(actor))

"""
    get_timeline(agent::AtpAgent; limit=nothing, cursor=nothing, algorithm=nothing)

Fetch the authenticated user's home timeline (`app.bsky.feed.getTimeline`).
"""
get_timeline(
    agent::AtpAgent;
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
    algorithm::Union{AbstractString, Nothing} = nothing,
) = xrpc(agent, API.App.Bsky.Feed.GetTimeline; limit, cursor, algorithm)

"""
    get_author_feed(agent::AtpAgent, actor; limit=nothing, cursor=nothing, filter=nothing, includePins=nothing)

Fetch posts and reposts authored by `actor` (`app.bsky.feed.getAuthorFeed`).
"""
get_author_feed(
    agent::AtpAgent,
    actor::Union{Handle, DID, AbstractString};
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
    filter::Union{AbstractString, Nothing} = nothing,
    includePins::Union{Bool, Nothing} = nothing,
) = xrpc(agent, API.App.Bsky.Feed.GetAuthorFeed; actor = string(actor), limit, cursor, filter, includePins)

"""
    get_post_thread(agent::AtpAgent, uri; depth=nothing, parentHeight=nothing)

Fetch a post thread rooted at `uri` (`AtUri` or string) via `app.bsky.feed.getPostThread`.
"""
get_post_thread(
    agent::AtpAgent,
    uri::Union{AtUri, AbstractString};
    depth::Union{Integer, Nothing} = nothing,
    parentHeight::Union{Integer, Nothing} = nothing,
) = xrpc(agent, API.App.Bsky.Feed.GetPostThread; uri = convert(AtUri, uri), depth, parentHeight)

"""
    get_record(agent::AtpAgent, repo, collection, rkey; cid=nothing)
    get_record(agent::AtpAgent, uri::AtUri; cid=nothing)

Fetch a repository record via `com.atproto.repo.getRecord`.
"""
get_record(
    agent::AtpAgent,
    repo::Union{Handle, DID, AbstractString},
    collection::Union{NSID, AbstractString},
    rkey::Union{RecordKey, TID, AbstractString};
    cid::Union{AbstractString, Nothing} = nothing,
) = xrpc(
    agent,
    API.Com.Atproto.Repo.GetRecord;
    repo = string(repo),
    collection = convert(NSID, collection),
    rkey = convert(RecordKey, rkey),
    cid = isnothing(cid) ? nothing : String(cid),
)

function get_record(agent::AtpAgent, uri::AtUri; cid::Union{AbstractString, Nothing} = nothing)
    (isnothing(uri.collection) || isnothing(uri.rkey)) &&
        throw(ArgumentError("AT-URI must include both collection and record key: $(uri)"))
    return get_record(agent, uri.authority, uri.collection, uri.rkey; cid)
end

"""
    list_records(agent::AtpAgent, repo, collection; limit=nothing, cursor=nothing, reverse=nothing)

List records in a repository collection via `com.atproto.repo.listRecords`.
"""
list_records(
    agent::AtpAgent,
    repo::Union{Handle, DID, AbstractString},
    collection::Union{NSID, AbstractString};
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
    reverse::Union{Bool, Nothing} = nothing,
) = xrpc(
    agent,
    API.Com.Atproto.Repo.ListRecords;
    repo = string(repo),
    collection = convert(NSID, collection),
    limit,
    cursor,
    reverse,
)

"""
    create_record(agent::AtpAgent, collection, record; repo=nothing, rkey=nothing, validate=nothing, swapCommit=nothing)
    create_record(agent::AtpAgent, record::LexiconRecord; repo=nothing, rkey=nothing, validate=nothing, swapCommit=nothing)

Create a new record via `com.atproto.repo.createRecord`. When `repo` is omitted,
defaults to the authenticated session's DID. When `record` is a [`LexiconRecord`](@ref),
`collection` may also be omitted and is inferred from `lexicon_type(record)`.
"""
function create_record(
    agent::AtpAgent,
    collection::Union{NSID, AbstractString},
    record;
    repo = nothing,
    rkey::Union{RecordKey, TID, AbstractString, Nothing} = nothing,
    validate::Union{Bool, Nothing} = nothing,
    swapCommit::Union{AbstractString, Nothing} = nothing,
)
    rec = record isa LexiconObject ? record : convert(LexiconObject, record)
    return xrpc(
        agent,
        API.Com.Atproto.Repo.CreateRecord;
        repo = _default_repo(agent, repo),
        collection = convert(NSID, collection),
        record = rec,
        rkey = isnothing(rkey) ? nothing : convert(RecordKey, rkey),
        validate,
        swapCommit = isnothing(swapCommit) ? nothing : String(swapCommit),
    )
end

function create_record(
    agent::AtpAgent,
    record::LexiconRecord;
    repo = nothing,
    rkey::Union{RecordKey, TID, AbstractString, Nothing} = nothing,
    validate::Union{Bool, Nothing} = nothing,
    swapCommit::Union{AbstractString, Nothing} = nothing,
)
    col = lexicon_type(record)
    isnothing(col) && throw(ArgumentError("Cannot infer collection NSID for $(typeof(record))"))
    return create_record(agent, NSID(col), record; repo, rkey, validate, swapCommit)
end

"""
    put_record(agent::AtpAgent, collection, rkey, record; repo=nothing, validate=nothing, swapRecord=nothing, swapCommit=nothing)

Create or replace a record at a specific `rkey` via `com.atproto.repo.putRecord`.
"""
function put_record(
    agent::AtpAgent,
    collection::Union{NSID, AbstractString},
    rkey::Union{RecordKey, TID, AbstractString},
    record;
    repo = nothing,
    validate::Union{Bool, Nothing} = nothing,
    swapRecord::Union{AbstractString, Nothing} = nothing,
    swapCommit::Union{AbstractString, Nothing} = nothing,
)
    rec = record isa LexiconObject ? record : convert(LexiconObject, record)
    return xrpc(
        agent,
        API.Com.Atproto.Repo.PutRecord;
        repo = _default_repo(agent, repo),
        collection = convert(NSID, collection),
        rkey = convert(RecordKey, rkey),
        record = rec,
        validate,
        swapRecord = isnothing(swapRecord) ? nothing : String(swapRecord),
        swapCommit = isnothing(swapCommit) ? nothing : String(swapCommit),
    )
end

"""
    delete_record(agent::AtpAgent, collection, rkey; repo=nothing, swapRecord=nothing, swapCommit=nothing)
    delete_record(agent::AtpAgent, uri::AtUri; swapRecord=nothing, swapCommit=nothing)

Delete a repository record via `com.atproto.repo.deleteRecord`.
"""
function delete_record(
    agent::AtpAgent,
    collection::Union{NSID, AbstractString},
    rkey::Union{RecordKey, TID, AbstractString};
    repo = nothing,
    swapRecord::Union{AbstractString, Nothing} = nothing,
    swapCommit::Union{AbstractString, Nothing} = nothing,
)
    return xrpc(
        agent,
        API.Com.Atproto.Repo.DeleteRecord;
        repo = _default_repo(agent, repo),
        collection = convert(NSID, collection),
        rkey = convert(RecordKey, rkey),
        swapRecord = isnothing(swapRecord) ? nothing : String(swapRecord),
        swapCommit = isnothing(swapCommit) ? nothing : String(swapCommit),
    )
end

function delete_record(
    agent::AtpAgent,
    uri::AtUri;
    swapRecord::Union{AbstractString, Nothing} = nothing,
    swapCommit::Union{AbstractString, Nothing} = nothing,
)
    (isnothing(uri.collection) || isnothing(uri.rkey)) &&
        throw(ArgumentError("AT-URI must include both collection and record key: $(uri)"))
    return delete_record(agent, uri.collection, uri.rkey; repo = uri.authority, swapRecord, swapCommit)
end

"""
    upload_blob(agent::AtpAgent, data::AbstractVector{UInt8}, mime_type::AbstractString) -> ComAtprotoRepoUploadBlobOutput

Upload binary blob bytes via `com.atproto.repo.uploadBlob` with the given `mime_type`.
"""
upload_blob(agent::AtpAgent, data::AbstractVector{UInt8}, mime_type::AbstractString) =
    xrpc(agent, API.Com.Atproto.Repo.UploadBlob; input = data, content_type = String(mime_type))

"""
    post!(agent::AtpAgent, text::AbstractString; reply=nothing, embed=nothing, facets=nothing, langs=nothing, tags=nothing, labels=nothing, createdAt=ATDateTime(Dates.now(Dates.UTC)))

Create and publish a Bluesky `app.bsky.feed.post` record in the authenticated user's repo.
"""
function post!(
    agent::AtpAgent,
    text::AbstractString;
    reply = nothing,
    embed = nothing,
    facets = nothing,
    langs::Union{AbstractVector{<:AbstractString}, Nothing} = nothing,
    tags::Union{AbstractVector{<:AbstractString}, Nothing} = nothing,
    labels = nothing,
    createdAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
)
    record = API.App.Bsky.Feed.Post.Main(
        text = String(text),
        createdAt = String(createdAt),
        reply = reply,
        embed = embed,
        facets = facets,
        langs = isnothing(langs) ? nothing : String[String(l) for l in langs],
        tags = isnothing(tags) ? nothing : String[String(t) for t in tags],
        labels = labels,
    )
    return create_record(agent, record)
end
