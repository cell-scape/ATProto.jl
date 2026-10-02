# ATProto.jl Roadmap

A feature-complete AT Protocol SDK for Julia, ported from the Bluesky team's
reference implementations (TypeScript `atproto` monorepo, Go `indigo`), their
tooling (`jetstream`, `pds`), and community implementations (`atproto-py`,
`atproto-crates`, `atex`, `zat`).

Reference sources live in `docs/reference/`:

| Reference | Location | Notes |
|---|---|---|
| TypeScript (authoritative) | `docs/reference/atproto/packages/*` | Most complete; spec-canonical |
| Go | `docs/reference/indigo/*` | Maintained by the devs; great for repo/sync/events |
| Python SDK | `docs/reference/atproto-py` | Best community SDK; rich client + firehose |
| Rust crates | `docs/reference/atproto-crates` | |
| Jetstream | `docs/reference/jetstream` | WebSocket firehose |
| Cookbook / guides | `docs/reference/cookbook`, `deploy-recipes` | |

## Architecture

```
src/
  ATProto.jl            top-level module, re-exports public API
  Syntax/               identifier & primitive syntax types (M1)
  Crypto/               multibase, multihash, CID, DID keys, signing (M2)
  DagCbor/              canonical DAG-CBOR encode/decode with CID tag 42 (M3)
  DID/                  DID documents, did:plc + did:web resolution (M4)
  Identity/             handle→DID resolution: DNS TXT + well-known (M5)
  XRPC/                 XRPC client, sessions, auth refresh, subscriptions (M6)
  Lexicon/              lexicon schemas, validation, blob refs (M7)
  Repo/                 MST, CAR, commits, block storage, applyWrites (M8)
  API/                  generated lexicon client namespaces + Agent (M9)
  RichText/             facet detection, TextBuilder (M10)
  OAuth/                atproto OAuth client (PKCE, DPoP, PAR) (M11)
  Jetstream/            firehose subscriber (M12)
```

Each milestone lands with its reference test vectors ported to `test/`.

## Milestones

### M1 — Syntax (`packages/syntax`, `indigo/atproto/syntax`) — ✅ DONE
Identifiers and primitives, zero non-stdlib dependencies:
- [x] DID syntax (`did:method:content`, ≤2048 chars)
- [x] Handle syntax (domain rules, ≤253 chars, TLD checks, disallowed TLDs)
- [x] AtIdentifier (DID-or-Handle dispatch)
- [x] NSID (segments, authority reversal, name)
- [x] TID (13-char base32-sortable; 53-bit µs + 10-bit clockid codec)
- [x] RecordKey (1–512 chars, no `.`/`..`)
- [x] AT-URI (parse/build, collection/rkey accessors, query, fragment)
- [x] Datetime (RFC 3339 ∩ ISO 8601 ∩ HTML; serialize/normalize)
- [x] Language (BCP 47 grammar + strict parse)
- [x] Tests ported from TS/Go test suites

### M2 — Crypto (`packages/crypto`, `indigo/atproto/crypto`) — ✅ DONE
- [x] Varint, multibase (base16/32/58btc/64 variants, all 9 multibase prefixes)
- [x] Multihash (sha2-256, identity), CID v0/v1 with codec registry
- [x] `did:key` / multikey parsing & formatting (p256 0x8024, secp256k1 0xe7)
- [x] Signatures: secp256k1 + P-256 via libcrypto (OpenSSL 3) — compact
      r||s, low-S normalization, strict verification (malleable opt-in)
- [ ] Key rotation / recovered keys (`Secp256k1Recovery`) — deferred to M4 (PLC)
- [x] Fixtures generated from multiformats/@noble (the TS reference's own deps)

### M3 — DAG-CBOR (`@ipld/dag-cbor`, spec: ipld.io/specs/codecs/dag-cbor) — ✅ DONE
- [x] Canonical encoder (definite lengths only, float64 only, minimal-int rules,
      RFC 7049 length-first map-key ordering)
- [x] Strict decoder: rejects indefinite lengths, float16/32, unknown/bignum
      tags, non-string/unsorted/duplicate map keys, bad UTF-8, trailing bytes;
      tag-42 CID round-trip with 0x00 identity-prefix validation
- [x] 34 reference fixtures from @ipld/dag-cbor (the TS reference's codec),
      covering the full int range, unicode, bytes, nested structures, CIDs
- [x] Full native Int64/UInt64 support (a superset of the JS codec's ±2^53)

### M4 — DID (`packages/did`)
- [ ] DID document model + parsing (alsoKnownAs, verificationMethod, service)
- [ ] `did:plc` resolver + PLC operation types (`LegacyCreate`, `Operation`)
- [ ] `did:web` resolver; `PlcClient` for plc.directory API
- [ ] DID resolution caching

### M5 — Identity (`packages/identity`)
- [ ] Handle→DID: DNS TXT `_atproto.<handle>`, `https://<handle>/.well-known/atproto-did`
- [ ] DID→handle (from DID doc alsoKnownAs) + bidirectional verification
- [ ] `IdentityResolver` with caching + TTL, `InvalidHandleError` paths

### M6 — XRPC (`packages/xrpc`, `indigo/xrpc`)
- [ ] Client: `get`/`proc` with query/body encoding, `XRPCError` responses
- [ ] Parameter type coercion from lexicons (`integer`, `boolean`, `string`)
- [ ] Auth: `createSession`/`refreshSession`, automatic refresh on 401, `getAuthSession`
- [ ] `subscribe` (WebSocket, binary frames, ops streaming)

### M7 — Lexicon (`packages/lexicon`)
- [ ] Lexicon schema model: `XrpcQuery/Procedure`, `Record`, `Object`, refs, unions
- [ ] Record/params/body validation (types, closures, known/required fields)
- [ ] BlobRef: legacy + new (`$link`/`$bytes`) parsing + validation
- [ ] Lexicon doc loading from `docs/reference/atproto/lexicons`

### M8 — Repo (`packages/repo`, `indigo/{mst,repo,car,events}`)
- [ ] Block storage abstraction (`BlockStore`, memory + disk)
- [ ] MST: insert/remove/diff with tree-sharding, edit distance proof
- [ ] CAR: read/write (v1, v2), `CarBlockReader`/`Writer`, deferral
- [ ] Commit signing/verification, `DataDiff`, repo parse/read
- [ ] `applyWrites` semantics (puts/dels with MST/CAR updates)

### M9 — API client (`packages/api`, `atproto-py` client)
- [ ] Generated namespaces from lexicon docs (codegen script, typed structs)
- [ ] `com.atproto.*` + `app.bsky.*` coverage
- [ ] `Agent`/`SessionAgent` with login, auth refresh, proxy headers
- [ ] `uploadBlob`, pagination helpers (`cursor`), `describeGenerator` conveniences

### M10 — RichText (`packages/api` richtext, `atproto-py` rich_text)
- [ ] UTF-8 ↔ UTF-16 index mapping (JS interop: facets use UTF-16 units)
- [ ] Detectors: mentions (`@handle`), URLs, tags (`#tag`), emojis
- [ ] `TextBuilder` with entity insertion; facet validation/munging

### M11 — OAuth (`packages/oauth`)
- [ ] Client metadata, dynamic client registration (PAR)
- [ ] PKCE (S256), DPoP-bound requests, authorization URL building
- [ ] Token exchange/refresh, `AtprotoServerAuth` requests
- [ ] Circular redirect/callback handling per atproto OAuth spec

### M12 — Jetstream / Firehose (`jetstream`, `indigo/events`)
- [ ] WebSocket subscriber with reconnect/backoff + cursor management
- [ ] Event parsing (`#commit` ops: create/update/delete, identity, account, info)
- [ ] Typed callbacks + filtering by collection/DID

### M13 — Polish
- [ ] Documenter docs, docstrings for all public API
- [ ] Aqua.jl + JET.jl clean; CI (existing workflows)
- [ ] Benchmarks for MST/CAR/CBOR hot paths
- [ ] README quickstart + examples

## Conventions

- Julia ≥ 1.10; prefer stdlib; each milestone adds deps only when required
  (HTTP.jl for M4–M6, crypto backend decision in M2)
- Immutable structs; `@kwdef` where keyword constructors help
- `is_valid_x(s)::Bool` predicates + `x(s)` constructors that throw typed
  `InvalidXError`s; validation error messages follow the TS reference wording
- Every module gets reference-test-vector ports; Aqua/JET stay green
