```@meta
CurrentModule = ATProto
DocTestSetup = quote
    using ATProto
    using JSON
end
```

# Tutorial: Building a Bluesky App

In this tutorial, you will build the core building blocks of a real Bluesky application
using **ATProto.jl**—combining identity verification, typed Lexicon queries, lazy
pagination, RichText composition & rendering, and real-time Jetstream firehose streaming.

Complete runnable versions of all examples below live in the repository's `examples/`
directory (`examples/bluesky_cli.jl`, `examples/jetstream_monitor.jl`, and
`examples/richtext_renderer.jl`).

---

## Step 1: Resolve & Verify an Identity

In the AT Protocol, handles are mutable domain names while DIDs (`did:plc:...`,
`did:web:...`) are permanent account identifiers. A handle claim is only trustworthy
when **bidirectionally verified**: DNS/HTTPS maps `handle → DID`, and the DID document's
`alsoKnownAs` maps `DID → handle`.

```julia
using ATProto

id = resolve_identity(handle"bsky.app")
println("DID      : ", id.did)
println("Handle   : ", id.handle)
println("Verified : ", id.handle_verified)
println("PDS      : ", id.pds)
```

If you resolve many accounts in a loop (e.g. a bot or analytics job), reuse a single
[`IdentityResolver`](@ref) to benefit from thread-safe TTL caching:

```julia
resolver = IdentityResolver(cache_ttl = 600.0) # cache for 10 minutes
doc = resolve_did(resolver, did"did:plc:z72i7hdynmk6r22z27h6tvur")
pds_endpoint(doc)
```

---

## Step 2: Inspect Feeds, Threads & Open Unions

ATProto.jl generates concrete Julia structs for all 237 vendored Lexicon schemas.
Union fields (like `post.embed` or `thread.replies`) automatically dispatch on their
JSON `"$type"` discriminator—and fall back losslessly to [`UnknownObject`](@ref) if
Bluesky introduces a new embed type in the future.

```julia
using ATProto

pub = AtpAgent(PUBLIC_APPVIEW)

function summarize_embed(embed)
    isnothing(embed) && return ""
    embed isa API.AppBskyEmbedImagesView          && return "[$(length(embed.images)) images]"
    embed isa API.AppBskyEmbedVideoView           && return "[video]"
    embed isa API.AppBskyEmbedExternalView        && return "[link: $(embed.external.title)]"
    embed isa API.AppBskyEmbedRecordView          && return "[quote post]"
    embed isa API.AppBskyEmbedRecordWithMediaView && return "[quote + media]"
    embed isa UnknownObject                       && return "[$(something(lexicon_type(embed), "unknown"))]"
    return "[embed]"
end

# Lazily fetch across cursor pages using Base.Iterators
feed_iter = eachitem(pub, API.App.Bsky.Feed.GetAuthorFeed; actor = handle"bsky.app", limit = 25)
for item in Iterators.take(feed_iter, 10)
    post = item.post
    rec = post.record
    rec isa API.AppBskyFeedPost || continue
    println("@", post.author.handle, ": ", rec.text, " ", summarize_embed(post.embed))
end
```

Because `eachitem` infers the exact element type (`AppBskyFeedDefsFeedViewPost`) and
fetches pages lazily, `Iterators.take(feed_iter, 10)` only issues a single HTTP request.

---

## Step 3: Compose & Render RichText Posts

Bluesky annotations (mentions, clickable links, and hashtags) are stored as
`app.bsky.richtext.facet` entries using **0-based UTF-8 byte slices** (`byteStart`
inclusive, `byteEnd` exclusive). Multi-byte characters like emojis (`🚀` = 4 UTF-8 bytes)
shift every subsequent byte offset.

### Programmatic Construction (`RichTextDoc` Builder)

Use the `do`-block builder when you want custom anchor text (like linking the word
`"ATProto.jl"` to its GitHub URL) with guaranteed exact UTF-8 byte offsets:

```jldoctest richtext_tutorial
julia> rt = RichTextDoc() do b
           add_text!(b, "🚀 Exploring ")
           add_link!(b, "ATProto.jl", "https://github.com/cell-scape/ATProto.jl")
           add_text!(b, " with ")
           add_mention!(b, "@bsky.app", did"did:plc:z72i7hdynmk6r22z27h6tvur")
           add_text!(b, " ")
           add_tag!(b, "#JuliaLang")
       end;

julia> grapheme_length(rt) <= 300 && byte_length(rt) <= 3000
true

julia> length(rt.facets)
3

julia> byte_slice(rt.text, rt.facets[1].index)
"ATProto.jl"
```

### Rendering to Markdown or HTML via `segments`

[`segments`](@ref) slices any `RichTextDoc` (built locally or received from Bluesky)
into ordered plain and annotated [`RichTextSegment`](@ref)s:

```jldoctest richtext_tutorial
julia> function to_markdown(rt::RichTextDoc)
           io = IOBuffer()
           for seg in segments(rt)
               if is_link(seg)
                   print(io, "[", seg.text, "](", link_uri(seg), ")")
               elseif is_mention(seg)
                   print(io, "[", seg.text, "](https://bsky.app/profile/", mention_did(seg), ")")
               elseif is_tag(seg)
                   print(io, "[", seg.text, "](https://bsky.app/hashtag/", tag_value(seg), ")")
               else
                   print(io, seg.text)
               end
           end
           return String(take!(io))
       end;

julia> to_markdown(rt)
"🚀 Exploring [ATProto.jl](https://github.com/cell-scape/ATProto.jl) with [@bsky.app](https://bsky.app/profile/did:plc:z72i7hdynmk6r22z27h6tvur) [#JuliaLang](https://bsky.app/hashtag/JuliaLang)"
```

### Automatic Detection & Publishing

When starting from plain user text, [`richtext`](@ref) detects links (preserving
balanced parentheses like Wikipedia URLs), hashtags, and—when given an `AtpAgent` or
resolver dictionary—mentions:

```jldoctest
julia> lookup = Dict(handle"bsky.app" => did"did:plc:z72i7hdynmk6r22z27h6tvur");

julia> auto_rt = richtext("See @bsky.app at https://julialang.org #JuliaLang!"; resolve_handle = lookup);

julia> [(byte_slice(auto_rt.text, f.index), lexicon_type(first(f.features))) for f in auto_rt.facets]
3-element Vector{Tuple{String, String}}:
 ("@bsky.app", "app.bsky.richtext.facet#mention")
 ("https://julialang.org", "app.bsky.richtext.facet#link")
 ("#JuliaLang", "app.bsky.richtext.facet#tag")
```

To publish with an authenticated `AtpAgent`, pass the `RichTextDoc` directly to [`post!`](@ref):

```julia
agent = AtpAgent()
login!(agent, ENV["BSKY_HANDLE"], ENV["BSKY_APP_PASSWORD"])
rt = richtext(agent, "🚀 Hello @bsky.app from https://julialang.org #JuliaLang!")
created = post!(agent, rt; langs = ["en"])
```

---

## Step 4: Upload an Image Blob & Attach an Embed

Binary procedures like `com.atproto.repo.uploadBlob` accept raw bytes and a MIME type,
returning a typed [`BlobRef`](@ref) you can attach straight to a post embed:

```julia
png_bytes = read("logo.png")
blob = upload_blob(agent, png_bytes, "image/png").blob

embed = API.App.Bsky.Embed.Images.Main(
    images = [
        API.App.Bsky.Embed.Images.Image(
            image = blob,
            alt = "Julia programming language logo",
            aspectRatio = API.App.Bsky.Embed.Defs.AspectRatio(width = 800, height = 600),
        ),
    ],
)

post!(agent, "Look at this plot!"; embed = embed, langs = ["en"])
```

---

## Step 5: Stream Real-Time Events with Jetstream

[`subscribe_jetstream`](@ref) opens a resilient WebSocket stream backed by a
`Channel{JetstreamEvent}`, deserializing commit records straight into generated
`ATProto.API` structs and automatically reconnecting with a configurable cursor rewind
(`cursor_rewind_us = 5_000_000` by default) if the network drops:

```julia
using ATProto

julia_posts = 0
resume_cursor = nothing

subscribe_jetstream(
    wanted_collections = ["app.bsky.feed.post"],
    cursor_rewind_us = 5_000_000,
) do stream
    for ev in stream
        if ev isa JetstreamCommitEvent && ev.operation === :create && ev.record isa API.AppBskyFeedPost
            if occursin("julia", lowercase(ev.record.text))
                julia_posts += 1
                println(aturi(ev), " => ", ev.record.text)
                julia_posts >= 5 && break
            end
        end
    end
    resume_cursor = last_cursor(stream)
end

println("Stopped cleanly. Restart without missing events using cursor = ", resume_cursor)
```

You can also change collection or DID filters on the fly without reconnecting via
[`update_options!`](@ref):

```julia
update_options!(stream; wanted_collections = ["app.bsky.feed.post", "app.bsky.feed.like"])
```

---

## Running the Bundled Examples

Try the runnable CLI examples directly from the repository root:

```bash
# Inspect an account profile & verified DID identity
julia --project=. examples/bluesky_cli.jl profile bsky.app

# Paginate recent posts with ANSI-colored links, mentions & hashtags
julia --project=. examples/bluesky_cli.jl feed bsky.app --limit 5

# Preview RichText facet detection without publishing
julia --project=. examples/bluesky_cli.jl post "🚀 Hello @bsky.app https://julialang.org #JuliaLang" --dry-run

# Live multi-collection Jetstream throughput & hashtag monitor
julia --project=. examples/jetstream_monitor.jl --count 200 --seconds 10

# RichText -> HTML / Markdown / wire JSON demo
julia --project=. examples/richtext_renderer.jl
```

Or launch the interactive **Tachikoma.jl Retro CRT Bluesky TUI Deck** (isolated in
`examples/tui/Project.toml` so `Tachikoma.jl` is not added to core `ATProto.jl`
dependencies — see [Building a Retro CRT Bluesky TUI](@ref) for a full step-by-step
architectural walkthrough):

```bash
julia --project=examples/tui -e 'using Pkg; Pkg.instantiate()'
julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl --actor bsky.app
```
