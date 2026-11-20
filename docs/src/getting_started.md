```@meta
CurrentModule = ATProto
DocTestSetup = quote
    using ATProto
    using ATProto.Syntax: authority, collection, rkey, is_valid_did
end
```

# Getting Started

This guide walks through installing **ATProto.jl**, validating AT Protocol identifiers,
making unauthenticated public Bluesky queries, authenticating with an App Password,
and persisting sessions cleanly.

## Installation

ATProto.jl requires **Julia 1.10 or newer**. Add it from GitHub using Julia's package manager:

```julia
using Pkg
Pkg.add(url = "https://github.com/cell-scape/ATProto.jl")
```

Or if you have cloned the repository locally:

```julia
using Pkg
Pkg.develop(path = "/path/to/ATProto.jl")
```

## 1. Validated Syntax Literals

AT Protocol uses strict ASCII syntax for handles, DIDs, NSIDs, record keys, TIDs,
and AT-URIs. ATProto.jl exposes immutable, validated value types along with
compile-time string macros:

```jldoctest
julia> h = handle"Bsky.App" # normalized to lowercase
Handle("bsky.app")

julia> d = did"did:plc:z72i7hdynmk6r22z27h6tvur"
DID("did:plc:z72i7hdynmk6r22z27h6tvur")

julia> n = nsid"app.bsky.feed.post"
NSID("app.bsky.feed.post")

julia> u = at"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"
AtUri("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y")

julia> (ATProto.Syntax.authority(u), ATProto.Syntax.collection(u), ATProto.Syntax.rkey(u))
(DID("did:plc:z72i7hdynmk6r22z27h6tvur"), NSID("app.bsky.feed.post"), RecordKey("3jui7kd54zh2y"))
```

For untrusted runtime input, use `tryparse` (non-throwing), `parse` (throws [`SyntaxError`](@ref)),
or the validators in `ATProto.Syntax`:

```jldoctest
julia> tryparse(Handle, "alice.bsky.social")
Handle("alice.bsky.social")

julia> tryparse(Handle, "not a handle") === nothing
true

julia> ATProto.Syntax.is_valid_did("did:plc:z72i7hdynmk6r22z27h6tvur")
true
```

## 2. Public (Unauthenticated) Queries

Many Bluesky AppView endpoints require no login when pointed at [`PUBLIC_APPVIEW`](@ref)
(`https://public.api.bsky.app`):

```julia
using ATProto

pub = AtpAgent(PUBLIC_APPVIEW)

# Fetch a profile
profile = get_profile(pub, handle"bsky.app")
println(profile.displayName, " has ", profile.followersCount, " followers")

# Lazily paginate posts across cursor pages
for item in Iterators.take(eachitem(pub, API.App.Bsky.Feed.GetAuthorFeed; actor = handle"bsky.app", limit = 25), 10)
    if item.post.record isa API.AppBskyFeedPost
        println("- ", item.post.record.text)
    end
end
```

## 3. Authenticated Sessions & PDS Routing

For writing records, reading your home timeline, or uploading blobs, create an
**App Password** in Bluesky (*Settings → Privacy and Security → App Passwords*) rather
than using your main account password:

```julia
using ATProto

agent = AtpAgent() # defaults to DEFAULT_SERVICE ("https://bsky.social")
sess = login!(agent, ENV["BSKY_HANDLE"], ENV["BSKY_APP_PASSWORD"])

# AtpAgent automatically routes subsequent requests to the PDS from didDoc
println("Authenticated as @", sess.handle, " on ", service_url(agent))

# Publish a post with automatic link/mention/hashtag facets
rt = richtext(agent, "🚀 Posting from Julia with ATProto.jl! https://julialang.org #JuliaLang")
created = post!(agent, rt; langs = ["en"])
println("Published: ", created.uri)
```

### Automatic Token Refresh & Session Persistence

`AtpAgent` automatically refreshes expired access tokens on HTTP `400`/`401`
`ExpiredToken` responses using single-flight locking (safe across concurrent `Task`s).
Pass `on_session_change` to persist refreshed tokens to disk, and restore them later
with [`resume_session!`](@ref):

```julia
agent = AtpAgent(
    on_session_change = (event, sess) -> begin
        @info "Session event" event authenticated = !isnothing(sess)
        # Save `sess` fields if event in (:create, :refresh)
    end,
)
```

## 4. Calling Any of the 193 Lexicon Endpoints

Every Bluesky, ATProto, Chat, and Ozone Lexicon endpoint is available through [`xrpc`](@ref)
by NSID string, `NSID`, endpoint spec, or hierarchical namespace module:

```julia
# All three are equivalent:
xrpc(pub, "app.bsky.actor.searchActors"; q = "julialang", limit = 5)
xrpc(pub, nsid"app.bsky.actor.searchActors"; q = "julialang", limit = 5)
xrpc(pub, API.App.Bsky.Actor.SearchActors; q = "julialang", limit = 5)
```

For proxy-routed services (such as Bluesky Chat DMs) or third-party labelers, create a
lightweight header view that shares your live session and refresh lock:

```julia
chat_agent = with_proxy(agent, "did:web:api.bsky.chat#bsky_chat")
convos = xrpc(chat_agent, API.Chat.Bsky.Convo.ListConvos; limit = 10)
```

## Next Steps

- Follow the step-by-step [Tutorial: Building a Bluesky App](@ref) to build a CLI,
  RichText renderer, and live Jetstream firehose monitor.
- Browse runnable scripts in the repository's `examples/` directory.
- Dive into the module reference pages in the sidebar.
