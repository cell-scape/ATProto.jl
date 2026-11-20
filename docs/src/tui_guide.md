```@meta
CurrentModule = ATProto
DocTestSetup = quote
    using ATProto
    using ATProto.Syntax: is_valid_handle, is_valid_did, authority, collection, rkey
end
```

# Building a Retro CRT Bluesky TUI

This step-by-step guide walks through how the bundled **BSKY·DECK** terminal viewer
(`examples/tui/`) is built using **ATProto.jl** and **Tachikoma.jl**. Along the way,
each step highlights **how the AT Protocol network differs fundamentally from a
traditional centralized web app** — and how ATProto.jl models those primitives directly
in Julia.

```bash
# Run the finished app from the repository root
julia --project=examples/tui -e 'using Pkg; Pkg.instantiate()'
julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl --actor bsky.app
```

---

## How AT Protocol Differs from a Traditional Web App

If you are used to writing clients for centralized REST APIs, several things in the TUI
codebase will look surprisingly different at first glance. Those differences come
directly from AT Protocol's federated architecture:

| Concern | Traditional Web App | AT Protocol / Bluesky (`ATProto.jl`) |
|:--------|:--------------------|:-------------------------------------|
| **Server topology** | One monolithic API (`api.example.com`) gated by developer API keys | Split across public **AppViews** (`AtpAgent(PUBLIC_APPVIEW)` — zero API keys) for aggregated reads, and each user's **Personal Data Server (PDS)** (`auto_pds = true`) for writes & personal state |
| **User identity** | Mutable username column in one company's database | Permanent decentralized **DID** (`did:plc:...` / `did:web:...`) paired with a DNS/HTTPS **Handle**, trusted only after **bidirectional verification** (`resolve_identity`) |
| **Record addressing** | Auto-increment integer IDs (`/posts/42`) | Content-addressed signed repo records identified by **`AtUri`** (`at://<did>/<nsid>/<rkey>`) and pinned to a cryptographic hash (**`CID`**) via `StrongRef` |
| **Schemas & embeds** | Closed JSON contract owned by one backend team | Open decentralized **Lexicons** with `$type` discriminators; clients handle known structs and preserve unknown future types via [`UnknownObject`](@ref) |
| **Formatted text** | Server-parsed Markdown or stored HTML | Plain UTF-8 text + out-of-band **0-based UTF-8 byte-offset facets** (`ATProto.RichText`) with independent grapheme (`300`) and byte (`3000`) budgets |
| **Real-time events** | Polling or paid webhook / enterprise firehose tiers | Open real-time **Jetstream** WebSocket firehose (`subscribe_jetstream`) with microsecond `time_us` resume cursors |

Every tab in **BSKY·DECK** maps directly onto one of these architectural pillars:

- **`AT-5150` + `PVM-14` (`1 Feed`)**: AppView reads, cursor pagination, content-addressed `AtUri`/`CID` records, `StrongRef` likes/reposts/replies, open-union embeds, and byte-indexed RichText rendering.
- **`VT-AT220` (`2 Thread`)**: Recursive open-union thread trees (`ThreadViewPost` / `NotFoundPost` / `BlockedPost`).
- **`IBM-3270` (`3 Profile`)**: Standalone bidirectional DID ↔ handle cryptographic verification (`resolve_identity`).
- **`JS-MODEM` + `TEK-4010` + `TTY-LIVE` (`4 Firehose`)**: Open Jetstream WebSocket streaming into an Elm `TaskQueue` and live events/sec `Sparkline`.

---

## Step 1: Isolating Dependencies & AppView vs. PDS Routing

### Why this matters in AT Protocol

In a traditional social API, even reading a public post usually requires registering an
OAuth app and shipping an API key. In AT Protocol, public network state is indexed by
**AppViews** (such as `https://public.api.bsky.app`) that answer unauthenticated XRPC
queries openly. When a user *does* sign in, their writes and home timeline do **not** go
to a single hardcoded server — they go to whichever **Personal Data Server (PDS)** hosts
their repository (whether `puffball.us-east.host.bsky.network` or a self-hosted PDS on
their own domain).

### Project setup

Keep UI dependencies (`Tachikoma.jl`) out of core `ATProto.jl` by isolating the TUI in
`examples/tui/Project.toml` and stacking the repository root onto `LOAD_PATH`:

```julia
# examples/tui/bluesky_tui.jl
const _REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
if !(_REPO_ROOT in LOAD_PATH)
    push!(LOAD_PATH, _REPO_ROOT)
end
```

### Connecting read-only first, upgrading seamlessly on login

Start `BlueskyModel` with [`PUBLIC_APPVIEW`](@ref) so anyone can browse profiles, feeds,
threads, search, and the Jetstream firehose with zero credentials:

```julia
agent = AtpAgent(PUBLIC_APPVIEW) # read-only public AppView; no API key required
```

When the user presses `L` and enters their handle + Bluesky App Password, `BlueskyTUI`
spawns a background task on Tachikoma's `TaskQueue`:

```julia
spawn_task!(m.queue, :login_done) do
    agent = AtpAgent() # default entry service (auto_pds = true)
    sess = login!(agent, handle, app_password)
    return (agent = agent, session = sess)
end
```

Because `auto_pds = true` is enabled by default on [`AtpAgent`](@ref):
1. `login!` inspects the `didDoc` returned by `com.atproto.server.createSession` and
   extracts the account's `#atproto_pds` service endpoint.
2. Subsequent calls (`get_timeline`, `post!`, `create_record`, `delete_record`) are
   routed automatically to the user's actual PDS (`service_url(agent)`).
3. If an access JWT expires while the TUI stays open for hours, `AtpAgent` performs a
   single-flight `refreshSession` automatically and retries the request transparently.

---

## Step 2: Bidirectional Cryptographic Identity (`IBM-3270` Profile Monitor)

### Why this matters in AT Protocol

On a centralized platform, `"@bsky.app"` is just a string in a database owned by the
company. On AT Protocol, a handle is a domain name claimed by a user, and a **DID**
(`did:plc:...` or `did:web:...`) is their permanent cryptographic anchor. Either side
could lie on its own:

- Someone could put `at://bsky.app` inside their DID document without owning `bsky.app`.
- A domain owner could point `_atproto.example.com` at someone else's DID.

Therefore, AT Protocol clients validate identifiers strictly and verify **both
directions** before trusting a handle.

### Live input validation in the Go-to-Actor (`g`) modal

Before making any network call, validate user input using `ATProto.Syntax`:

```jldoctest
julia> is_valid_handle("bsky.app")
true

julia> is_valid_did("did:plc:z72i7hdynmk6r22z27h6tvur")
true

julia> is_valid_handle("not a handle!")
false
```

In `examples/tui/BlueskyTUI.jl`, this validator runs on every keystroke inside
Tachikoma's `TextInput`, giving instant `✓ Valid handle` / `✓ Valid DID` / `✕ Invalid`
feedback before hitting the network.

### Independent verification in the `IBM-3270` Profile tab

When loading a profile (`o` on any post, or `3`), the TUI fetches the AppView profile
*and* independently resolves the account's DID document and handle DNS/HTTPS record via
[`resolve_identity`](@ref):

```julia
spawn_task!(m.queue, :profile_loaded) do
    prof = get_profile(agent, actor)
    id_info = try
        resolver(prof.did) # defaults to ATProto.resolve_identity
    catch
        nothing
    end
    return (req_id = req_id, silent = silent, profile = prof, identity = id_info)
end
```

That gives the **AT Protocol Identity Certificate** inside the `IBM-3270` CRT monitor
four pieces of cryptographic ground truth that never rely solely on the AppView's word:
- `id_info.did` — permanent DID anchor
- `id_info.handle_verified` — `true` only if the DID document's `alsoKnownAs` and the
  handle's DNS TXT / HTTPS `.well-known/atproto-did` agree
- `id_info.pds` — the user's Personal Data Server URL
- `id_info.signing_key` — `DIDVerificationMethod` (`publicKeyMultibase` + key `type`, e.g. `Multikey`)

---

## Step 3: Content-Addressed Repositories, StrongRefs & Pagination (`AT-5150` + `PVM-14`)

### Why this matters in AT Protocol

Traditional REST APIs assign mutable integer IDs (`POST /posts/123/like`). In AT
Protocol, every action you take — posting, liking, reposting, following — creates a
signed **record** inside *your own* repository, addressed by an [`AtUri`](@ref):

```jldoctest
julia> u = at"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"
AtUri("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y")

julia> (authority(u), collection(u), rkey(u))
(DID("did:plc:z72i7hdynmk6r22z27h6tvur"), NSID("app.bsky.feed.post"), RecordKey("3jui7kd54zh2y"))
```

Because a repository owner could theoretically overwrite a record at the same `AtUri`,
interactions like Likes, Reposts, and Replies reference a **`ComAtprotoRepoStrongRef`**
pairing both the `uri::AtUri` **and** the content hash `cid::String`.

### Cursor pagination across Feed, Timeline, and Search

The `AT-5150` left panel supports three feed sources with identical opaque-cursor
pagination (`n` loads the next page):

```julia
if mode === :timeline
    out = get_timeline(agent; limit = 25, cursor = cursor)
elseif mode === :search
    out = xrpc(agent, API.App.Bsky.Feed.SearchPosts; q = query, limit = 25, cursor = cursor)
else
    out = get_author_feed(agent, actor; limit = 25, cursor = cursor)
end
```

And every response automatically updates `rate_limit(agent)` from HTTP `RateLimit-*`
headers, which the TUI displays live as a `RL:2995/3000` capsule in the bottom bar.

### Creating and deleting repository records (Like `l`, Repost `R`, Reply `p`)

Liking a post writes an `app.bsky.feed.like` record into the authenticated user's PDS
referencing the target post's `StrongRef`; unliking deletes that record by extracting its
`RecordKey` from `post.viewer.like`:

```julia
# Like
rec = API.AppBskyFeedLike(
    subject = API.ComAtprotoRepoStrongRef(uri = post.uri, cid = post.cid),
    createdAt = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z",
)
out = create_record(agent, "app.bsky.feed.like", rec)

# Unlike
rk = ATProto.Syntax.rkey(post.viewer.like)
delete_record(agent, "app.bsky.feed.like", rk)
```

Replying (`p`) builds an `API.AppBskyFeedPostReplyRef(root = root_ref, parent = parent_ref)`
so nested threads always preserve both the thread root and the immediate parent `StrongRef`.

---

## Step 4: Open Unions & Forward Compatibility (Embeds & `VT-AT220` Threads)

### Why this matters in AT Protocol

In an open federated protocol, other apps and future protocol upgrades can attach new
embed types or custom records onto the same network at any time. A rigid schema decoder
that throws on unrecognized `$type` tags breaks whenever the network evolves.

`ATProto.jl` decodes known Lexicon `$type` discriminators into concrete Julia structs
under `ATProto.API`, and wraps unrecognized `$type` values into [`UnknownObject`](@ref)
while preserving their raw fields and type name:

```jldoctest
julia> unk = UnknownObject("com.example.futureEmbed", Dict{String, Any}("version" => 2))
UnknownObject("com.example.futureEmbed", Dict{String, Any}("version" => 2))

julia> lexicon_type(unk)
"com.example.futureEmbed"
```

In `examples/tui/rendering.jl`, both `embed_to_span_lines` and `_render_thread_post!` use
Julia multiple-dispatch / `isa` checks over open union variants:

- **Embeds (`post.embed`)**:
  - `API.AppBskyEmbedImagesView` → `▣ Images (N)` card with alt text, aspect ratio, and OSC-8 fullsize URL
  - `API.AppBskyEmbedVideoView` → `▶ Video` card with alt text and playlist URL
  - `API.AppBskyEmbedExternalView` → `◈ Link Card` with title, description, and clickable URI
  - `API.AppBskyEmbedRecordView` / `AppBskyEmbedRecordWithMediaView` → nested `❝ Quote` card (handling `ViewRecord`, `ViewNotFound`, `ViewBlocked`, `ViewDetached`, `GeneratorView`, `ListView`)
  - `UnknownObject` → clean `◇ [Embed: <type>]` fallback — never crashes the TUI!
- **Threads (`get_post_thread`)**:
  - Walks `node.parent` upwards to build the ancestor chain and recurses through `node.replies`, handling `AppBskyFeedDefsThreadViewPost`, `AppBskyFeedDefsNotFoundPost`, and `AppBskyFeedDefsBlockedPost` cleanly inside the `VT-AT220` terminal.

---

## Step 5: UTF-8 Byte-Indexed RichText Facets & Grapheme Budgets

### Why this matters in AT Protocol

Instead of storing raw HTML or Markdown (which invites XSS and dialect drift across
clients), AT Protocol posts store plain UTF-8 `text` alongside an array of **`facets`**.
Each facet carries a **`ByteSlice(byteStart, byteEnd)`** using **0-based UTF-8 byte
offsets**, while Bluesky enforces post length limits in **extended grapheme clusters**
(`300` graphemes) AND **UTF-8 bytes** (`3000` bytes).

Notice how dramatically UTF-8 bytes, Julia `Char` codepoints, and user-perceived
graphemes diverge when emoji are present:

```jldoctest
julia> txt = "🚀 Hello @bsky.app https://julialang.org #JuliaLang"
"🚀 Hello @bsky.app https://julialang.org #JuliaLang"

julia> (grapheme_length(txt), byte_length(txt))
(50, 53)

julia> length(detect_mentions(txt)), length(detect_links(txt)), length(detect_tags(txt))
(1, 1, 1)
```

If you sliced by Julia `length` or character index instead of UTF-8 byte offsets, every
mention/link/hashtag after `🚀` would shift by 3 bytes and corrupt the link!

### Rendering RichText to Tachikoma `Span`s with OSC-8 Clickable Links

`examples/tui/rendering.jl` turns any `RichTextDoc` into styled, newline-preserving
`Vector{Vector{Span}}` lines using [`segments`](@ref):

```julia
function segment_style(seg::RichTextSegment)::Style
    if is_mention(seg)
        did = mention_did(seg)
        return tstyle(:accent, bold = true, hyperlink = isnothing(did) ? "" : "https://bsky.app/profile/$did")
    elseif is_link(seg)
        return tstyle(:primary, underline = true, hyperlink = something(link_uri(seg), ""))
    elseif is_tag(seg)
        tag = something(tag_value(seg), "")
        return tstyle(:warning, bold = true, hyperlink = isempty(tag) ? "" : "https://bsky.app/hashtag/$tag")
    else
        return tstyle(:text)
    end
end
```

Because Tachikoma's `Style` supports OSC-8 `hyperlink`, mentions, links, hashtags, and
embed cards become **clickable terminal links** in modern terminals (Ghostty, Kitty,
WezTerm, iTerm2, Alacritty).

### Zero-latency Compose preview + DID resolution on publish

While typing in the Compose modal (`c` / `p`):
1. `grapheme_length(txt)` and `byte_length(txt)` drive a shimmering Tachikoma `Gauge`
   (`47/300 gr · 50/3000 B`) shifting from `:success` → `:warning` → `:error`.
2. Pure client-side `detect_mentions`, `detect_links`, and `detect_tags` update live
   facet counters with **zero network lag**.
3. When the user hits `Ctrl+D` to publish, `richtext(agent, txt)` resolves each `@handle`
   to its authoritative `DID` via `com.atproto.identity.resolveHandle` and `post!(agent, rt; ...)`
   writes the signed post record to the user's PDS! (In read-only mode, `Ctrl+D` runs a
   safe dry-run validation preview.)

---

## Step 6: Streaming the Open Firehose (`JS-MODEM` + `TEK-4010` + `TTY-LIVE`)

### Why this matters in AT Protocol

On centralized networks, seeing live public activity across the whole platform either
requires polling individual users or paying for enterprise firehose access. On AT
Protocol, the entire public network streams openly through relays and **Jetstream**
(JSON-over-WebSocket). Every event carries a monotonic microsecond timestamp cursor
(`time_us`) so clients can disconnect and resume cleanly.

### Bridging `subscribe_jetstream` into Tachikoma's single-threaded Elm loop

Tachikoma follows the Elm architecture: all model mutations happen on the main UI thread
inside `update!(model, event)`. To keep the UI running smoothly at 30–60 fps even when
dozens of commits arrive per second, `examples/tui/BlueskyTUI.jl`:

1. Spawns a background `Threads.@spawn` reader tied to a Tachikoma `CancelToken` and a
   `Ref{Any}` holding the active `JetstreamStream` (so `Space` or `q` cancels and closes
   the WebSocket immediately in `cleanup!`).
2. Filters on collections (`["app.bsky.feed.post"]`, `["app.bsky.feed.post", "app.bsky.feed.like", "app.bsky.feed.repost"]`, or all collections — cycled with `C`).
3. **Batches** events (flushing every 12 events or 120 ms) into `TaskEvent(:jetstream_batch, ...)`
   pushed onto `m.queue.channel` and wakes the render loop via `m.queue.on_ready()`.
4. Uses `spawn_timer!(m.queue, :tick_1s, 1.0; repeat = true)` to roll each second's event
   count into a 60-second ring buffer rendered by a Tachikoma `Sparkline` inside the
   **`TEK-4010` storage-tube oscilloscope** hood!

```julia
stream = subscribe_jetstream(; wanted_collections = collections, reconnect = true)
for ev in stream
    is_cancelled(token) && break
    if ev isa JetstreamCommitEvent && ev.operation === :create && ev.record isa API.AppBskyFeedPost
        # batch into TaskEvent(:jetstream_batch, (items = ..., cursor = last_cursor(stream)))
    end
end
```

---

## Step 7: Elm Architecture, Retro CRT Enclosures & Headless Testing

### Preventing stale async races with monotonic request IDs

Whenever the user jumps rapidly between accounts (`g`) or triggers searches (`/`), two
HTTP responses could return out of order. `BlueskyModel` tags every async fetch with a
monotonic counter (`m.feed_req_id`, `m.thread_req_id`, `m.profile_req_id`) and ignores
stale `TaskEvent`s whose `req_id` no longer matches the latest request.

### Layering vintage CRT tube monitors in Tachikoma

All four hardware enclosures (`AT-5150`, `PVM-14`, `VT-AT220`, `IBM-3270`, `JS-MODEM`,
`TEK-4010`, `TTY-LIVE`) are drawn by a single reusable primitive, `render_crt_monitor!`
(`examples/tui/rendering.jl`), using four visual layers:

1. **Ambient backdrop**: `DotWaveBackground` renders whisper-soft rolling braille terrain
   waves on the outer canvas (`b` toggles).
2. **Outer polycarbonate chassis**: `_fill_surface!` with `_chassis_bg()` + `BOX_HEAVY`
   or `BOX_DOUBLE` frame (`border_shimmer!` when focused) + top cooling louvers (`≡≡≡`),
   model nameplate, chin controls (floppy bay `[▬▬▬▬●▬▬▬▬]`, rotary knobs `◉ BRT  ◉ CNT`,
   speaker grille `⋮⋮⋮⋮⋮`, breathing `● PWR` LED), and optional swivel pedestal
   (`╰═══╦═══╯` / `╭───────╨───────╮`).
3. **Recessed curved phosphor glass**: nested `BOX_ROUNDED` interior filled with darker
   `_crt_glass_bg()` and subtle alternating CRT scanline rows (`v` toggles). Because
   Tachikoma's `Buffer` preserves each cell's existing `bg` when text is drawn with
   `bg = NoColor()`, `ScrollPane` content inherits the raster scanlines automatically!
4. **Live phosphor themes**: pressing `P` cycles `esper` (Amber CRT) → `neuromancer`
   (P31 Green) → `kokaku` (Cyber Blue) → `outrun` → `catppuccin` → `paper` (Beige
   Terminal), and `view` detects `m.last_theme_name != theme().name` to re-theme cached
   `Span` buffers instantaneously.

### Deterministic headless testing with `Tachikoma.TestBackend`

Because `ATProto.AtpAgent` accepts a pluggable HTTP `transport` function, and
`BlueskyModel` accepts injectable `identity_resolver` and `jetstream_connector` hooks,
`examples/tui/test_tui.jl` drives the entire application headlessly with **zero live
network calls**:

```julia
agent = AtpAgent(PUBLIC_APPVIEW; transport = mock_transport)
m = BlueskyModel(;
    agent = agent,
    auto_fetch = false,
    auto_timer = false,
    auto_login = false,
    identity_resolver = mock_identity_resolver,
    jetstream_connector = cols -> MockJetstreamStream(mock_events),
)

Tachikoma.update!(m, KeyEvent('j'))
tb = TestBackend(120, 36)
f = Frame(tb.buf, Rect(1, 1, 120, 36), GraphicsRegion[], PixelSnapshot[])
Tachikoma.view(m, f)
@assert find_text(tb, "PVM-14") !== nothing
```

Run all 120 headless assertions anytime:

```bash
julia -t auto --project=examples/tui examples/tui/test_tui.jl
```
