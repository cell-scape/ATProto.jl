# ATProto.jl

AT Protocol (Bluesky) SDK for Julia.

## Features

- **Strict, zero-allocation Syntax primitives (`ATProto.Syntax`)**: validated immutable value types (`Handle`, `DID`, `NSID`, `RecordKey`, `TID`, `ATDateTime`, `AtUri`, BCP-47 languages), `Base.parse`/`tryparse`, compile-time string macros (`handle"..."`, `did"..."`, `nsid"..."`, `rkey"..."`, `tid"..."`, `at"..."`), and `JSON.jl` v1 / `StructUtils.jl` integration.
- **Cryptography, CIDs & DAG-CBOR (`ATProto.Crypto`, `ATProto.DagCbor`)**: varints, multibase encodings, SHA-256 & RIPEMD-160, CIDv1, `did:key` multikeys, ECDSA (`P-256` & `secp256k1`) signing/verification/recovery via `OpenSSL_jll`, and canonical IPLD DAG-CBOR serialization.
- **Repositories, MST & CAR Archives (`ATProto.Repo`)**: deterministic Merkle Search Trees (`MST`), block stores, MST diffs, CAR v1/v2 archive reader & writer, and signed v3 commit verification.
- **Generated Lexicon API & Runtime Validation (`ATProto.API`, `ATProto.Lexicon`)**: ahead-of-time code generator ([`scripts/generate_lexicons.jl`](scripts/generate_lexicons.jl)) producing typed structs, `$type` open-union dispatch (`UnknownObject` fallback), IPLD primitives (`CIDLink`, `ATBytes`, `BlobRef`), 193 XRPC endpoint specs, plus runtime Lexicon schema document parsing and record/XRPC payload validators.
- **Identity & PLC Verification (`ATProto.Identity`, `ATProto.PLC`)**: standalone `did:plc` (`plc.directory`) and `did:web` (`/.well-known/did.json`) resolution, PLC operation log & genesis verification, DNS TXT (DoH) + HTTPS handle resolution, bidirectional verification (`verify_handle`, `resolve_identity`), and TTL caching.
- **XRPC Client, OAuth 2.1 & Social Helpers (`ATProto.Client`, `ATProto.OAuth`)**: `AtpAgent` with JWT and OAuth 2.1 (PKCE + DPoP RFC 9449 + PAR + inter-service JWT auth) sessions, automatic PDS routing from `didDoc`, single-flight token refresh, rate-limit tracking, `atproto-proxy` / `atproto-accept-labelers` / chat views, lazy cursor pagination (`eachpage`, `eachitem`), and ergonomic social/chat/notification helpers.
- **RichText & Facets (`ATProto.RichText`)**: exact 0-based UTF-8 byte-offset facet detection (mentions, links with balanced-paren handling, Unicode hashtags), `AtpAgent`-backed deduplicated handle resolution, `RichTextBuilder` / `RichTextDoc` `do`-block builder, grapheme counting, and segment rendering (`segments`).
- **Jetstream WebSocket Streaming (`ATProto.Jetstream`)**: real-time Bluesky JSON firehose consumer backed by `Channel{JetstreamEvent}`, with typed commit/identity/account events, optional Zstandard compression (`Zstd_jll`), cursor checkpointing, live `options_update`, and automatic reconnect with cursor rewind.

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
  - [`examples/tui/bluesky_tui.jl`](examples/tui/bluesky_tui.jl) — interactive 6-tab retro-CRT Bluesky TUI viewer built with `Tachikoma.jl` (Feed/Timeline/Saved Feeds/Bookmarks, Thread tree, Profile + verified DID card + Follow/Mute, Notifications `DEC-LA120`, Chat DMs `TTY-DM300` via `with_proxy`, live Jetstream firehose + Sparkline, Image/Alt-Text gallery, quote-posts, likes/reposts)
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
