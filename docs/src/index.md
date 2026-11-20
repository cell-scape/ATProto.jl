```@meta
CurrentModule = ATProto
```

# ATProto.jl

**ATProto.jl** is a Julia SDK for the [AT Protocol](https://atproto.com) (Bluesky),
providing zero-allocation syntax validation, ahead-of-time generated Lexicon API types,
standalone DID/handle identity resolution, an authenticated XRPC client with lazy cursor
pagination, UTF-8 byte-offset RichText facets, and real-time Jetstream WebSocket streaming.

## Architecture Overview

| Module | Responsibility |
|:-------|:---------------|
| [Syntax Primitives](@ref) (`ATProto.Syntax`) | Strict ASCII validators, immutable value types (`Handle`, `DID`, `NSID`, `RecordKey`, `TID`, `ATDateTime`, `AtUri`), BCP-47 language tags, compile-time string macros |
| [Cryptography, CIDs & Multibase](@ref) (`ATProto.Crypto`) | Multibase/varint/multihash, CIDv0/v1, `did:key`, ECDSA (`ES256`/`ES256K`) via OpenSSL, secp256k1 key recovery |
| [DAG-CBOR Codec](@ref) (`ATProto.DagCbor`) | Strict canonical IPLD DAG-CBOR encode/decode with CID tag 42 and `DagBytes` |
| [Identity Resolution](@ref) (`ATProto.Identity`) | `did:plc` & `did:web` resolution, DNS TXT (DoH) & HTTPS handle resolution, bidirectional verification, TTL caching |
| [PLC Directory & DID Verification](@ref) (`ATProto.PLC`) | `plc.directory` audit log client, DID document parsers, genesis/rotation op verification |
| [Lexicon Schema Validation](@ref) (`ATProto.Lexicon`) | Runtime schema validator over the 237 bundled Lexicon JSON docs (`load_bundled_lexicons`) |
| [Repositories, MST & CAR Archives](@ref) (`ATProto.Repo`) | Merkle Search Trees (`MST`), CAR v1/v2 import & export, signed v3 repo commits & diffs |
| [Lexicon API & Code Generation](@ref) (`ATProto.API`) | Generated Lexicon structs (237 schemas, 193 endpoints), `$type` open-union dispatch (`UnknownObject` fallback), IPLD primitives (`CIDLink`, `ATBytes`, `BlobRef`) |
| [XRPC Client & Pagination](@ref) (`ATProto.Client`) | `AtpAgent`, JWT & OAuth sessions, PDS routing, single-flight refresh, `eachpage`/`eachitem`, social actions (`like!`, `repost!`, `follow!`, `reply!`, `quote_post!`), embeds, notifications, bookmarks, Chat DMs, session persistence |
| [OAuth 2.1 (PKCE + DPoP + PAR) & Service Auth](@ref) (`ATProto.OAuth`) | OAuth 2.1 metadata discovery, PAR, PKCE, DPoP proofs + nonce retry, `AtpAgent(oauth_session)`, inter-service JWT creation & verification |
| [RichText & Facets](@ref) (`ATProto.RichText`) | 0-based UTF-8 byte-offset facet detection (mentions, links, hashtags), `RichTextBuilder`, grapheme counting, segment rendering |
| [Jetstream Streaming](@ref) (`ATProto.Jetstream`) | Real-time `Channel{JetstreamEvent}` WebSocket firehose with Zstandard compression (`compress=true`, custom dicts), `options_update`, cursor-rewound reconnect & file checkpoints |

## Quickstart

```julia
using ATProto

# 1. Validated compile-time literals
d = did"did:plc:z72i7hdynmk6r22z27h6tvur"
h = handle"bsky.app"
u = at"at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y"

# 2. Public queries & lazy cursor pagination
pub = AtpAgent(PUBLIC_APPVIEW)
profile = get_profile(pub, h)
posts = collect(Iterators.take(
    eachitem(pub, API.App.Bsky.Feed.GetAuthorFeed; actor = h, limit = 25),
    50,
))

# 3. Authenticated posting with RichText facets
agent = AtpAgent()
login!(agent, "you.bsky.social", ENV["BSKY_APP_PASSWORD"])
rt = richtext(agent, "🚀 Hello @bsky.app from https://julialang.org #JuliaLang!")
post!(agent, rt; langs = ["en"])

# 4. Real-time Jetstream firehose
subscribe_jetstream(wanted_collections = ["app.bsky.feed.post"]) do stream
    for ev in Iterators.take(stream, 10)
        if ev isa JetstreamCommitEvent && ev.record isa API.AppBskyFeedPost
            println(ev.did, ": ", ev.record.text)
        end
    end
end
```

## Top-Level Helpers

```@docs
lexicons_path
get_lexicons
load_lexicon
```
