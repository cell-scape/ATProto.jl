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

# -----------------------------------------------------------------------------
# Social Actions (Like, Repost, Follow, Mute, Block)
# -----------------------------------------------------------------------------

_strong_ref(uri::Union{AtUri, AbstractString}, cid::AbstractString) =
    API.ComAtprotoRepoStrongRef(uri = convert(AtUri, uri), cid = String(cid))

_strong_ref(post::API.AppBskyFeedDefsPostView) =
    API.ComAtprotoRepoStrongRef(uri = post.uri, cid = post.cid)

"""
    like!(agent::AtpAgent, uri, cid; createdAt=ATDateTime(Dates.now(Dates.UTC)))
    like!(agent::AtpAgent, post::API.AppBskyFeedDefsPostView; createdAt=...)

Like a Bluesky post by creating an `app.bsky.feed.like` record in the authenticated
user's repository. Returns the `ComAtprotoRepoCreateRecordOutput` (containing the
new like record's `uri` and `cid`).
"""
function like!(
    agent::AtpAgent,
    uri::Union{AtUri, AbstractString},
    cid::AbstractString;
    createdAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
)
    rec = API.AppBskyFeedLike(
        subject = _strong_ref(uri, cid),
        createdAt = String(createdAt),
    )
    return create_record(agent, rec)
end

like!(agent::AtpAgent, post::API.AppBskyFeedDefsPostView; kwargs...) =
    like!(agent, post.uri, post.cid; kwargs...)

"""
    unlike!(agent::AtpAgent, like_uri::Union{AtUri, AbstractString})

Remove an existing like by deleting its `app.bsky.feed.like` record AT-URI
(e.g. `post.viewer.like`).
"""
unlike!(agent::AtpAgent, like_uri::Union{AtUri, AbstractString}) =
    delete_record(agent, convert(AtUri, like_uri))

"""
    repost!(agent::AtpAgent, uri, cid; createdAt=ATDateTime(Dates.now(Dates.UTC)))
    repost!(agent::AtpAgent, post::API.AppBskyFeedDefsPostView; createdAt=...)

Repost a Bluesky post by creating an `app.bsky.feed.repost` record.
"""
function repost!(
    agent::AtpAgent,
    uri::Union{AtUri, AbstractString},
    cid::AbstractString;
    createdAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
)
    rec = API.AppBskyFeedRepost(
        subject = _strong_ref(uri, cid),
        createdAt = String(createdAt),
    )
    return create_record(agent, rec)
end

repost!(agent::AtpAgent, post::API.AppBskyFeedDefsPostView; kwargs...) =
    repost!(agent, post.uri, post.cid; kwargs...)

"""
    unrepost!(agent::AtpAgent, repost_uri::Union{AtUri, AbstractString})

Remove an existing repost by deleting its `app.bsky.feed.repost` record AT-URI
(e.g. `post.viewer.repost`).
"""
unrepost!(agent::AtpAgent, repost_uri::Union{AtUri, AbstractString}) =
    delete_record(agent, convert(AtUri, repost_uri))

"""
    follow!(agent::AtpAgent, subject::Union{DID, AbstractString}; createdAt=ATDateTime(Dates.now(Dates.UTC)))

Follow an account (by `DID`) by creating an `app.bsky.graph.follow` record.
"""
function follow!(
    agent::AtpAgent,
    subject::Union{DID, AbstractString};
    createdAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
)
    rec = API.AppBskyGraphFollow(
        subject = convert(DID, subject),
        createdAt = String(createdAt),
    )
    return create_record(agent, rec)
end

"""
    unfollow!(agent::AtpAgent, follow_uri::Union{AtUri, AbstractString})

Unfollow an account by deleting its `app.bsky.graph.follow` record AT-URI
(e.g. `profile.viewer.following`).
"""
unfollow!(agent::AtpAgent, follow_uri::Union{AtUri, AbstractString}) =
    delete_record(agent, convert(AtUri, follow_uri))

"""
    mute!(agent::AtpAgent, actor::Union{Handle, DID, AbstractString})

Mute `actor` privately via `app.bsky.graph.muteActor`.
"""
mute!(agent::AtpAgent, actor::Union{Handle, DID, AbstractString}) =
    xrpc(agent, API.App.Bsky.Graph.MuteActor; actor = string(actor))

"""
    unmute!(agent::AtpAgent, actor::Union{Handle, DID, AbstractString})

Unmute `actor` via `app.bsky.graph.unmuteActor`.
"""
unmute!(agent::AtpAgent, actor::Union{Handle, DID, AbstractString}) =
    xrpc(agent, API.App.Bsky.Graph.UnmuteActor; actor = string(actor))

"""
    block!(agent::AtpAgent, subject::Union{DID, AbstractString}; createdAt=ATDateTime(Dates.now(Dates.UTC)))

Block an account (by `DID`) by creating an `app.bsky.graph.block` record.
"""
function block!(
    agent::AtpAgent,
    subject::Union{DID, AbstractString};
    createdAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
)
    rec = API.AppBskyGraphBlock(
        subject = convert(DID, subject),
        createdAt = String(createdAt),
    )
    return create_record(agent, rec)
end

"""
    unblock!(agent::AtpAgent, block_uri::Union{AtUri, AbstractString})

Remove a block by deleting its `app.bsky.graph.block` record AT-URI.
"""
unblock!(agent::AtpAgent, block_uri::Union{AtUri, AbstractString}) =
    delete_record(agent, convert(AtUri, block_uri))

# -----------------------------------------------------------------------------
# Reply, Quote & Embed Builders
# -----------------------------------------------------------------------------

"""
    reply_ref(parent::API.AppBskyFeedDefsPostView; root=nothing) -> API.AppBskyFeedPostReplyRef

Build an `app.bsky.feed.post#replyRef` for replying to `parent`. When `root` is
omitted and `parent.record` is itself a reply, preserves the thread's original
`root` reference automatically.
"""
function reply_ref(
    parent::API.AppBskyFeedDefsPostView;
    root::Union{API.ComAtprotoRepoStrongRef, API.AppBskyFeedDefsPostView, Nothing} = nothing,
)
    parent_sr = _strong_ref(parent)
    root_sr = if root isa API.ComAtprotoRepoStrongRef
        root
    elseif root isa API.AppBskyFeedDefsPostView
        _strong_ref(root)
    elseif parent.record isa API.AppBskyFeedPost && !isnothing(parent.record.reply)
        parent.record.reply.root
    else
        parent_sr
    end
    return API.AppBskyFeedPostReplyRef(root = root_sr, parent = parent_sr)
end

"""
    reply!(agent::AtpAgent, parent::API.AppBskyFeedDefsPostView, text::AbstractString; root=nothing, kwargs...)

Publish a reply to `parent`, automatically constructing the thread's
`AppBskyFeedPostReplyRef`. Additional keyword arguments are forwarded to [`post!`](@ref).
"""
function reply!(
    agent::AtpAgent,
    parent::API.AppBskyFeedDefsPostView,
    text::AbstractString;
    root::Union{API.ComAtprotoRepoStrongRef, API.AppBskyFeedDefsPostView, Nothing} = nothing,
    kwargs...,
)
    return post!(agent, text; reply = reply_ref(parent; root), kwargs...)
end

"""
    quote_embed(uri, cid) -> API.AppBskyEmbedRecord
    quote_embed(post::API.AppBskyFeedDefsPostView) -> API.AppBskyEmbedRecord

Construct an `app.bsky.embed.record` embed referencing an existing post or record.
"""
quote_embed(uri::Union{AtUri, AbstractString}, cid::AbstractString) =
    API.AppBskyEmbedRecord(record = _strong_ref(uri, cid))

quote_embed(post::API.AppBskyFeedDefsPostView) =
    API.AppBskyEmbedRecord(record = _strong_ref(post))

"""
    quote_with_media_embed(media::LexiconObject, uri, cid) -> API.AppBskyEmbedRecordWithMedia
    quote_with_media_embed(media::LexiconObject, post::API.AppBskyFeedDefsPostView) -> API.AppBskyEmbedRecordWithMedia

Combine a media embed (e.g. from [`image_embed`](@ref) or [`external_embed`](@ref))
with a quoted record embed (`app.bsky.embed.recordWithMedia`).
"""
quote_with_media_embed(media::LexiconObject, uri::Union{AtUri, AbstractString}, cid::AbstractString) =
    API.AppBskyEmbedRecordWithMedia(media = media, record = quote_embed(uri, cid))

quote_with_media_embed(media::LexiconObject, post::API.AppBskyFeedDefsPostView) =
    API.AppBskyEmbedRecordWithMedia(media = media, record = quote_embed(post))

"""
    quote_post!(agent::AtpAgent, uri, cid, text::AbstractString; media=nothing, kwargs...)
    quote_post!(agent::AtpAgent, quoted::API.AppBskyFeedDefsPostView, text::AbstractString; media=nothing, kwargs...)

Publish a quote-post citing `(uri, cid)` or `quoted`. When `media` is also supplied,
wraps both in `app.bsky.embed.recordWithMedia`.
"""
function quote_post!(
    agent::AtpAgent,
    uri::Union{AtUri, AbstractString},
    cid::AbstractString,
    text::AbstractString;
    media::Union{LexiconObject, Nothing} = nothing,
    kwargs...,
)
    emb = isnothing(media) ? quote_embed(uri, cid) : quote_with_media_embed(media, uri, cid)
    return post!(agent, text; embed = emb, kwargs...)
end

quote_post!(
    agent::AtpAgent,
    quoted::API.AppBskyFeedDefsPostView,
    text::AbstractString;
    kwargs...,
) = quote_post!(agent, quoted.uri, quoted.cid, text; kwargs...)

"""
    external_embed(uri::AbstractString; title::AbstractString, description::AbstractString="", thumb=nothing) -> API.AppBskyEmbedExternal

Construct an `app.bsky.embed.external` link card embed.
"""
function external_embed(
    uri::AbstractString;
    title::AbstractString,
    description::AbstractString = "",
    thumb::Union{API.BlobRef, Nothing} = nothing,
)
    ext = API.AppBskyEmbedExternalExternal(
        uri = String(uri),
        title = String(title),
        description = String(description),
        thumb = thumb,
    )
    return API.AppBskyEmbedExternal(external = ext)
end

function _to_aspect_ratio(ar)
    isnothing(ar) && return nothing
    ar isa API.AppBskyEmbedDefsAspectRatio && return ar
    ar isa Tuple{Integer, Integer} && return API.AppBskyEmbedDefsAspectRatio(width = Int(ar[1]), height = Int(ar[2]))
    throw(ArgumentError("aspectRatio must be an AppBskyEmbedDefsAspectRatio, (width, height) tuple, or nothing"))
end

"""
    image_embed(images::AbstractVector{API.AppBskyEmbedImagesImage}) -> API.AppBskyEmbedImages
    image_embed(agent::AtpAgent, items::AbstractVector) -> API.AppBskyEmbedImages

Construct an `app.bsky.embed.images` embed (up to 4 images).

The `agent` form accepts any mixture of:
- `API.AppBskyEmbedImagesImage`
- `(blob::BlobRef, alt::AbstractString)` or `(blob::BlobRef, alt::AbstractString, (width, height))`
- `(bytes::AbstractVector{UInt8}, mime::AbstractString, alt::AbstractString)` (or with trailing `(width, height)`) — automatically uploaded via [`upload_blob`](@ref)
"""
function image_embed(images::AbstractVector{API.AppBskyEmbedImagesImage})
    isempty(images) && throw(ArgumentError("image_embed requires at least one image"))
    length(images) > 4 && throw(ArgumentError("Bluesky supports at most 4 images per post (got $(length(images)))"))
    return API.AppBskyEmbedImages(images = collect(images))
end

function image_embed(agent::AtpAgent, items::AbstractVector)
    isempty(items) && throw(ArgumentError("image_embed requires at least one image"))
    length(items) > 4 && throw(ArgumentError("Bluesky supports at most 4 images per post (got $(length(items)))"))
    built = API.AppBskyEmbedImagesImage[]
    for item in items
        if item isa API.AppBskyEmbedImagesImage
            push!(built, item)
        elseif item isa Tuple && length(item) in (2, 3) && item[1] isa API.BlobRef
            ar = length(item) == 3 ? _to_aspect_ratio(item[3]) : nothing
            push!(built, API.AppBskyEmbedImagesImage(image = item[1], alt = String(item[2]), aspectRatio = ar))
        elseif item isa Tuple && length(item) in (3, 4) && item[1] isa AbstractVector{UInt8}
            up = upload_blob(agent, item[1], String(item[2]))
            ar = length(item) == 4 ? _to_aspect_ratio(item[4]) : nothing
            push!(built, API.AppBskyEmbedImagesImage(image = up.blob, alt = String(item[3]), aspectRatio = ar))
        else
            throw(ArgumentError("Unsupported image_embed item of type $(typeof(item))"))
        end
    end
    return API.AppBskyEmbedImages(images = built)
end

# -----------------------------------------------------------------------------
# Notifications, Preferences / Saved Feeds, Bookmarks & Chat DMs
# -----------------------------------------------------------------------------

"""
    get_notifications(agent::AtpAgent; limit=nothing, cursor=nothing, priority=nothing, seenAt=nothing)

Fetch notifications for the authenticated account via `app.bsky.notification.listNotifications`.
"""
get_notifications(
    agent::AtpAgent;
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
    priority::Union{Bool, Nothing} = nothing,
    seenAt::Union{ATDateTime, AbstractString, Nothing} = nothing,
) = xrpc(
    agent,
    API.App.Bsky.Notification.ListNotifications;
    limit,
    cursor,
    priority,
    seenAt = isnothing(seenAt) ? nothing : String(seenAt),
)

"""
    get_unread_count(agent::AtpAgent; priority=nothing, seenAt=nothing) -> Int

Return the unread notification count for the authenticated account via
`app.bsky.notification.getUnreadCount`.
"""
function get_unread_count(
    agent::AtpAgent;
    priority::Union{Bool, Nothing} = nothing,
    seenAt::Union{ATDateTime, AbstractString, Nothing} = nothing,
)::Int
    out = xrpc(
        agent,
        API.App.Bsky.Notification.GetUnreadCount;
        priority,
        seenAt = isnothing(seenAt) ? nothing : String(seenAt),
    )
    return out.count
end

"""
    update_seen_notifications!(agent::AtpAgent; seenAt=ATDateTime(Dates.now(Dates.UTC)))

Mark notifications up to `seenAt` as seen via `app.bsky.notification.updateSeen`.
"""
update_seen_notifications!(
    agent::AtpAgent;
    seenAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
) = xrpc(agent, API.App.Bsky.Notification.UpdateSeen; seenAt = String(seenAt))

"""
    get_preferences(agent::AtpAgent)

Fetch private account preferences via `app.bsky.actor.getPreferences`.
"""
get_preferences(agent::AtpAgent) = xrpc(agent, API.App.Bsky.Actor.GetPreferences)

"""
    get_saved_feeds(agent::AtpAgent) -> Vector{API.AppBskyActorDefsSavedFeed}

Extract the authenticated account's saved & pinned feeds from `app.bsky.actor.getPreferences`
(supporting both `savedFeedsPrefV2` and legacy `savedFeedsPref`).
"""
function get_saved_feeds(agent::AtpAgent)::Vector{API.AppBskyActorDefsSavedFeed}
    out = get_preferences(agent)
    for pref in out.preferences
        if pref isa API.AppBskyActorDefsSavedFeedsPrefV2
            return pref.items
        end
    end
    for pref in out.preferences
        if pref isa API.AppBskyActorDefsSavedFeedsPref
            pinned_set = Set(String(u) for u in pref.pinned)
            items = API.AppBskyActorDefsSavedFeed[]
            for (i, u) in enumerate(pref.saved)
                us = String(u)
                t = occursin("/app.bsky.graph.list/", us) ? "list" : "feed"
                push!(items, API.AppBskyActorDefsSavedFeed(
                    id = string("legacy-", i),
                    pinned = us in pinned_set,
                    type = t,
                    value = us,
                ))
            end
            return items
        end
    end
    return API.AppBskyActorDefsSavedFeed[]
end

"""
    get_bookmarks(agent::AtpAgent; limit=nothing, cursor=nothing) -> Dict{String, Any}

Fetch private bookmarks for the authenticated account via `app.bsky.bookmark.getBookmarks`.
"""
function get_bookmarks(
    agent::AtpAgent;
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
)
    qs = _encode_query_params((limit = limit, cursor = cursor))
    resp = _xrpc_request(agent, "GET", NSID("app.bsky.bookmark.getBookmarks"); query_string = qs)
    body_str = _body_string(resp.body)
    return isempty(body_str) ? Dict{String, Any}("bookmarks" => Any[]) : JSON.parse(body_str, Dict{String, Any})
end

"""
    create_bookmark!(agent::AtpAgent, uri, cid) -> Nothing
    create_bookmark!(agent::AtpAgent, post::API.AppBskyFeedDefsPostView) -> Nothing

Bookmark a post privately via `app.bsky.bookmark.createBookmark`.
"""
function create_bookmark!(
    agent::AtpAgent,
    uri::Union{AtUri, AbstractString},
    cid::AbstractString,
)
    payload = JSON.json(Dict("uri" => string(convert(AtUri, uri)), "cid" => String(cid)))
    _xrpc_request(
        agent,
        "POST",
        NSID("app.bsky.bookmark.createBookmark");
        body = payload,
        content_type = "application/json",
    )
    return nothing
end

create_bookmark!(agent::AtpAgent, post::API.AppBskyFeedDefsPostView) =
    create_bookmark!(agent, post.uri, post.cid)

"""
    delete_bookmark!(agent::AtpAgent, uri::Union{AtUri, AbstractString}) -> Nothing

Remove a private bookmark via `app.bsky.bookmark.deleteBookmark`.
"""
function delete_bookmark!(agent::AtpAgent, uri::Union{AtUri, AbstractString})
    payload = JSON.json(Dict("uri" => string(convert(AtUri, uri))))
    _xrpc_request(
        agent,
        "POST",
        NSID("app.bsky.bookmark.deleteBookmark");
        body = payload,
        content_type = "application/json",
    )
    return nothing
end

"""
    DEFAULT_CHAT_PROXY

Default AT Protocol `atproto-proxy` service DID for Bluesky Direct Messages
(`"did:web:api.bsky.chat#bsky_chat"`).
"""
const DEFAULT_CHAT_PROXY = "did:web:api.bsky.chat#bsky_chat"

"""
    chat_agent(agent::AtpAgent; proxy=DEFAULT_CHAT_PROXY) -> AtpAgent

Return a proxy-routed view of `agent` configured for Bluesky Chat (`chat.bsky.*`)
endpoints, sharing the underlying session and refresh lock.
"""
chat_agent(agent::AtpAgent; proxy::AbstractString = DEFAULT_CHAT_PROXY) =
    isnothing(agent.proxy) ? with_proxy(agent, proxy) : agent

"""
    list_convos(agent::AtpAgent; limit=nothing, cursor=nothing, readState=nothing, status=nothing)

List Direct Message conversations via `chat.bsky.convo.listConvos` (automatically
applying the Bluesky Chat proxy header if not already set on `agent`).
"""
list_convos(
    agent::AtpAgent;
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
    readState::Union{AbstractString, Nothing} = nothing,
    status::Union{AbstractString, Nothing} = nothing,
) = xrpc(chat_agent(agent), API.Chat.Bsky.Convo.ListConvos; limit, cursor, readState, status)

"""
    get_convo_messages(agent::AtpAgent, convo_id::AbstractString; limit=nothing, cursor=nothing)

Fetch messages in a Direct Message conversation via `chat.bsky.convo.getMessages`.
"""
get_convo_messages(
    agent::AtpAgent,
    convo_id::AbstractString;
    limit::Union{Integer, Nothing} = nothing,
    cursor::Union{AbstractString, Nothing} = nothing,
) = xrpc(chat_agent(agent), API.Chat.Bsky.Convo.GetMessages; convoId = String(convo_id), limit, cursor)

"""
    send_chat_message!(agent::AtpAgent, convo_id::AbstractString, text::AbstractString; facets=nothing, embed=nothing)

Send a Direct Message in `convo_id` via `chat.bsky.convo.sendMessage`.
"""
function send_chat_message!(
    agent::AtpAgent,
    convo_id::AbstractString,
    text::AbstractString;
    facets = nothing,
    embed = nothing,
)
    msg = API.ChatBskyConvoDefsMessageInput(
        text = String(text),
        facets = facets,
        embed = embed,
    )
    return xrpc(chat_agent(agent), API.Chat.Bsky.Convo.SendMessage; convoId = String(convo_id), message = msg)
end

"""
    update_convo_read!(agent::AtpAgent, convo_id::AbstractString; messageId=nothing)

Mark a Direct Message conversation as read via `chat.bsky.convo.updateRead`.
"""
update_convo_read!(
    agent::AtpAgent,
    convo_id::AbstractString;
    messageId::Union{AbstractString, Nothing} = nothing,
) = xrpc(
    chat_agent(agent),
    API.Chat.Bsky.Convo.UpdateRead;
    convoId = String(convo_id),
    messageId = isnothing(messageId) ? nothing : String(messageId),
)
