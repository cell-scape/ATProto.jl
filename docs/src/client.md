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

## Reference

```@autodocs
Modules = [ATProto.Client]
Order = [:type, :function, :constant]
```
