# ATProto.jl

AT Protocol (Bluesky) SDK for Julia.

## Features

- **Strict, zero-allocation Syntax primitives (`ATProto.Syntax`)**: validated immutable value types (`Handle`, `DID`, `NSID`, `RecordKey`, `TID`, `ATDateTime`, `AtUri`), `Base.parse`/`tryparse`, compile-time string macros (`handle"..."`, `did"..."`, `nsid"..."`, `rkey"..."`, `tid"..."`, `at"..."`), and `JSON.jl` v1 / `StructUtils.jl` integration.
- **Generated Lexicon API (`ATProto.API`)**: ahead-of-time code generator ([`scripts/generate_lexicons.jl`](scripts/generate_lexicons.jl)) producing typed structs, `$type` open-union dispatch (`UnknownObject` fallback), IPLD primitives (`CIDLink`, `ATBytes`, `BlobRef`), 193 XRPC endpoint specs, and hierarchical NSID namespace modules (`ATProto.API.App.Bsky.Feed.Post.Main`).
- **Identity Resolution (`ATProto.Identity`)**: standalone `did:plc` (`plc.directory`) and `did:web` (`/.well-known/did.json`) resolution, DNS TXT (DoH) + HTTPS handle resolution, bidirectional verification (`verify_handle`, `resolve_identity`), and thread-safe TTL caching (`IdentityResolver`).
- **XRPC Client & Auth (`ATProto.Client`)**: `AtpAgent` with JWT session management, automatic PDS routing from `didDoc`, single-flight `ExpiredToken` refresh, rate-limit tracking, `atproto-proxy` / `atproto-accept-labelers` views, binary blob upload/download, and lazy Julia-native cursor pagination (`eachpage`, `eachitem`).
- **RichText & Facets (`ATProto.RichText`)**: exact 0-based UTF-8 byte-offset facet detection (mentions, links with balanced-paren handling, Unicode hashtags), `AtpAgent`-backed deduplicated handle resolution, `RichTextBuilder` / `RichTextDoc` `do`-block builder, grapheme counting, and segment rendering (`segments`).
- **Jetstream WebSocket Streaming (`ATProto.Jetstream`)**: real-time Bluesky JSON firehose consumer backed by `Channel{JetstreamEvent}`, with typed commit/identity/account events, live `options_update`, and automatic reconnect with cursor rewind.

## Quickstart

```julia
using ATProto

# Unauthenticated public queries & lazy pagination
pub = AtpAgent(PUBLIC_APPVIEW)
profile = get_profile(pub, handle"bsky.app")
posts = collect(Iterators.take(
    eachitem(pub, API.App.Bsky.Feed.GetAuthorFeed; actor=handle"bsky.app", limit=25),
    50,
))

# Authenticated PDS session
agent = AtpAgent()
login!(agent, "you.bsky.social", ENV["BSKY_APP_PASSWORD"])
post!(agent, "Hello from ATProto.jl!"; langs=["en"])

# Real-time Jetstream firehose
subscribe_jetstream(wanted_collections=["app.bsky.feed.post"]) do stream
    for ev in Iterators.take(stream, 10)
        if ev isa JetstreamCommitEvent && ev.record isa API.AppBskyFeedPost
            println(ev.did, ": ", ev.record.text)
        end
    end
end
```

## Examples & Documentation

- Runnable examples live in [`examples/`](examples/README.md):
  - [`examples/tui/bluesky_tui.jl`](examples/tui/bluesky_tui.jl) — interactive Bluesky TUI viewer built with `Tachikoma.jl` (Feed/Timeline, Thread tree, Profile + verified DID card, live Jetstream firehose + Sparkline, search, compose, likes/reposts)
  - [`examples/bluesky_cli.jl`](examples/bluesky_cli.jl) — full Bluesky CLI (`profile`, `feed`, `thread`, `firehose`, `post --dry-run`)
  - [`examples/jetstream_monitor.jl`](examples/jetstream_monitor.jl) — real-time Jetstream throughput & hashtag counter
  - [`examples/richtext_renderer.jl`](examples/richtext_renderer.jl) — RichText builder & HTML/Markdown renderer
- Documentation source (Getting Started, Tutorial, and API Reference) lives in [`docs/`](docs/src/index.md); build locally with:
  ```bash
  julia --project=docs -e 'push!(LOAD_PATH, pwd()); include("docs/make.jl")'
  ```

## Development

### Regenerate Lexicon Types
```bash
julia --project=. scripts/generate_lexicons.jl
```

### Run Tests (ParallelTestRunner + Aqua + JET + AllocCheck + Supposition)
```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
Run a subset of test files via `ParallelTestRunner`:
```bash
julia --project=test test/runtests.jl test_syntax richtext_tests alloc_tests
```

### Run Benchmarks & Profiling (Chairmarks, PkgBenchmark, PProf & SnoopCompile)
Fast microbenchmark table with Chairmarks.jl:
```bash
julia --project=benchmark benchmark/chairmarks.jl
```

CPU/allocation PProf profiles, TimerOutputs breakdown, and SnoopCompile invalidation audit:
```bash
julia --project=benchmark benchmark/profile.jl
```

Full suite / git regression judgement with PkgBenchmark.jl:
```bash
julia --project=benchmark -e 'using PkgBenchmark; println(export_markdown(benchmarkpkg(pwd())))'
```
