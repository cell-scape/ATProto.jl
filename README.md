# ATProto.jl

[![Build Status](https://github.com/cell-scape/ATProto.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/cell-scape/ATProto.jl/actions/workflows/CI.yml?query=branch%3Amain)

A feature-complete [AT Protocol](https://atproto.com) SDK for Julia — the decentralized social protocol powering [Bluesky](https://bsky.app).

Ported from the reference [TypeScript](https://github.com/bluesky-social/atproto) and [Go](https://github.com/bluesky-network/indigo) implementations maintained by the Bluesky team, together with community implementations. **~13,000 lines of Julia, 1,516 tests** (including property-based tests via [Supposition.jl](https://github.com/Seelengrab/Supposition.jl)).

## Quickstart

```julia
using ATProto

# Unauthenticated client — read public data
agent = Agent(; service = "https://bsky.social")

# Any of the 325 generated XRPC endpoints:
profile = ATProto.API.app.bsky.actor.get_profile(agent; actor = "bsky.app")

# Search posts
results = ATProto.API.app.bsky.feed.search_posts(agent; q = "julia lang")
```

### Login and post

```julia
using ATProto

agent = Agent(; service = "https://bsky.social")
session = login(agent, "alice.bsky.social", "your-app-password")

# Create a post
post = create_post(session, "Hello from Julia! 🎉")

# With facets (mentions, links, tags auto-detected)
using ATProto.RichText
rt = ATProto.RichText.RichText("Check out @bsky.app and https://julialang.org!")
detect_facets_without_resolution!(rt)
post = create_post(session, string(rt); facets = rt.facets)

# Upload a blob
blob = upload_blob(session, read("photo.png"), "image/png")

# Delete
delete_post(session, "3jzfcijpj2z2a")
```

### Identity resolution

```julia
using ATProto

# Server-side (PDS): fast, cached
did = resolve_handle(agent, "alice.bsky.social")

# Local: DNS TXT + HTTPS well-known, fully offline-capable
resolver = IdResolver(; timeout = 5.0)
verified_did = resolve_identity(resolver, "alice.example.com")
```

### Rich text

```julia
using ATProto.RichText

rt = ATProto.RichText.RichText("hello @alice.bsky.social #julia https://julialang.org")
detect_facets_without_resolution!(rt)

for seg in segments(rt)
    if is_mention(seg)
        println("mention: ", seg.text)
    elseif is_link(seg)
        println("link: ", seg.text)
    elseif is_tag(seg)
        println("tag: ", seg.text)
    end
end
```

### OAuth (DPoP)

```julia
using ATProto.OAuth

meta = OAuthClientMetadata(;
    client_id = "https://app.example.com/client-metadata.json",
    redirect_uris = ["https://app.example.com/callback"])

# Generate PKCE + DPoP key
pkce = generate_pkce()
dpop_key = generate_dpop_key()

# Build the authorization URL
auth_url = build_authorization_url(
    "https://bsky.social/oauth/authorize",
    meta.client_id, "https://app.example.com/callback";
    code_challenge = pkce.challenge,
    state = generate_nonce())

# ... user visits auth_url, gets redirected back with ?code=...&state=...

# Exchange the code for tokens (DPoP-bound)
tokens = exchange_code(
    "https://bsky.social/oauth/token",
    meta.client_id, "https://app.example.com/callback",
    auth_code, pkce.verifier; dpop_key = dpop_key)

# Make DPoP-bound requests
session = OAuthSession(;
    client_id = meta.client_id,
    token_endpoint = "https://bsky.social/oauth/token",
    dpop_key = dpop_key,
    access_token = tokens["access_token"],
    refresh_token = get(tokens, "refresh_token", nothing))

res = oauth_request(session, "GET",
    "https://bsky.social/xrpc/app.bsky.feed.getTimeline")
```

### Firehose / Jetstream

```julia
using ATProto.Jetstream

jetstream_subscribe("https://jetstream.bsky.social/subscribe";
    wanted_collections = ["app.bsky.feed.post"]) do event
    if event["kind"] == "commit"
        commit = event["commit"]
        if commit["operation"] == "create"
            println("new post: ", commit["collection"], "/", commit["rkey"])
        end
    end
end
```

### Low-level: MST, CAR, DAG-CBOR

```julia
using ATProto.Repo

# Build a Merkle Search Tree
store = MemoryBlockStore()
tree = mst_create(store)
tree = mst_add(tree, "com.example.post/3jzfcijpj2z2a", cid_for_dagcbor("record bytes"))

# The root CID is deterministic (insert-order independent)
root = mst_pointer(tree)

# Export to a CAR file
unstored = mst_get_unstored_blocks(tree)
put_blocks!(store, unstored.blocks)
car_bytes = write_car(CID[root], unstored.blocks)

# Sign a commit
key = generate_key(Secp256k1Key)
(commit_cid, commit_bytes) = create_commit(store, root, "did:plc:abc",
    "3jzfcijpj2z2a"; signing_key = key)
```

## Modules

| Module | Description |
|---|---|
| `ATProto.Syntax` | DID, handle, NSID, TID, record-key, AT-URI, datetime, BCP 47 language validation |
| `ATProto.Crypto` | Multibase, CID, SHA-256, RIPEMD-160, secp256k1/P-256 ECDSA (via OpenSSL), did:key, public-key recovery |
| `ATProto.DagCbor` | Canonical DAG-CBOR encode/decode with CID tag-42, strict mode |
| `ATProto.DID` | DID document parsing, did:plc/did:web resolvers, plc.directory client, PLC operation verification |
| `ATProto.Identity` | Handle resolution (DNS TXT + HTTPS well-known), bidirectional identity verification |
| `ATProto.XRPC` | XRPC client with lexicon JSON serialization, authenticated sessions, WebSocket subscriptions |
| `ATProto.Lexicon` | Lexicon document parsing/validation, value validation (records, params, unions, blobs) |
| `ATProto.Repo` | Merkle Search Tree, CAR archives, commit signing/verification, diffs |
| `ATProto.API` | Generated client for all 325 official XRPC endpoints, Agent/SessionAgent, record conveniences |
| `ATProto.RichText` | Facet detection (mentions, links, tags, cashtags), insert/delete with index adjustment |
| `ATProto.OAuth` | PKCE, DPoP proofs (RFC 9449), ES256/ES256K JWTs, client metadata, token exchange |
| `ATProto.Jetstream` | Firehose event types, frame parsing, WebSocket subscriber with reconnect |

## Testing

The test suite uses [Supposition.jl](https://github.com/Seelengrab/Supposition.jl) (the Julia Hypothesis port) for property-based testing of core invariants:

- **MST determinism**: insert-order independence, delete-matches-fresh-build, add-delete roundtrip
- **Codec round-trips**: base16/32/58/64, multibase, varint, CID
- **DAG-CBOR**: decode∘encode identity over generated value trees

Example suites cover the full API surface with cross-implementation fixtures (generated from `multiformats`/`@noble`/`@ipld` — the TypeScript reference's own dependencies).

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Requirements

- Julia ≥ 1.10
- OpenSSL (for ECDSA; provided by `OpenSSL_jll`)

## License

MIT
