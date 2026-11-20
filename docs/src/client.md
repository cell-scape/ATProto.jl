```@meta
CurrentModule = ATProto
```

# XRPC Client & Pagination

`ATProto.Client` implements `AtpAgent`, unified `xrpc` dispatch over all 193 generated
Lexicon endpoints, JWT session management with automatic single-flight `ExpiredToken`
refresh, rate-limit tracking, proxy/labeler views, and Julia-native cursor pagination.

## Unified `xrpc` Dispatch

`xrpc` dispatches on endpoint strings, `NSID`s, `QueryEndpoint`/`ProcedureEndpoint`
structs, or generated namespace modules directly:

```julia
using ATProto

pub = AtpAgent(PUBLIC_APPVIEW)
xrpc(pub, "app.bsky.actor.getProfile"; actor = handle"bsky.app")
xrpc(pub, API.App.Bsky.Actor.GetProfile; actor = handle"bsky.app")
```

## Lazy Cursor Pagination

`eachpage` and `eachitem` implement `Base.iterate` with tight `eltype` (auto-inferring
the items vector field across all 51 cursor-paginated endpoints) and compose directly
with `Base.Iterators`:

```julia
feed = collect(Iterators.take(
    eachitem(pub, API.App.Bsky.Feed.GetAuthorFeed; actor = handle"bsky.app", limit = 25),
    50,
))
```

## Social Actions, Embeds, Notifications, Bookmarks & Chat DMs

`ATProto.Client` includes ergonomic helpers over common Bluesky workflows:

- **Interactions & Graph**: [`like!`](@ref), [`unlike!`](@ref), [`repost!`](@ref), [`unrepost!`](@ref), [`follow!`](@ref), [`unfollow!`](@ref), [`mute!`](@ref), [`unmute!`](@ref), [`block!`](@ref), [`unblock!`](@ref)
- **Replies, Quotes & Embeds**: [`reply_ref`](@ref), [`reply!`](@ref), [`quote_post!`](@ref), [`quote_embed`](@ref), [`quote_with_media_embed`](@ref), [`image_embed`](@ref), [`external_embed`](@ref)
- **Notifications, Saved Feeds & Bookmarks**: [`get_notifications`](@ref), [`get_unread_count`](@ref), [`update_seen_notifications!`](@ref), [`get_preferences`](@ref), [`get_saved_feeds`](@ref), [`get_bookmarks`](@ref), [`create_bookmark!`](@ref), [`delete_bookmark!`](@ref)
- **Bluesky Chat DMs**: [`chat_agent`](@ref), [`list_convos`](@ref), [`get_convo_messages`](@ref), [`send_chat_message!`](@ref), [`update_convo_read!`](@ref)
- **Session File Persistence**: [`save_session`](@ref), [`load_session`](@ref), and `resume_session!(agent, path)`

## Reference

```@autodocs
Modules = [ATProto.Client]
Order = [:type, :function, :constant]
```
