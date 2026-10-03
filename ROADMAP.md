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

### M4 — DID (`packages/did`, `packages/identity`) — ✅ DONE
- [x] did:plc / did:web / atproto DID validation (ports of packages/did:
      plc base32 [a-z2-7] length rules, web URL building incl. %3A ports &
      localhost http, atproto path/port restrictions)
- [x] DidDocument model + strict parsing (id match, duplicate service ids)
- [x] AtprotoData extraction: handle, signing key (Multikey/EcdsaSecp256r1/
      EcdsaSecp256k1 verification methods), PDS/notif/feedgen endpoints
- [x] PlcResolver / WebResolver / DidResolver with injectable transport;
      stale-while-revalidate DidMemoryCache (stale 1h / max 24h defaults)
- [x] PlcClient: getDocument / getLastOperation / getAuditLog / getOps
- [x] PLC operation verification: LegacyCreate (secp256k1 recoverable sig via
      new recover_pubkey + genesis did derivation via pure-Julia ripemd160),
      Operation/Tombstone rotation-key sigs (verify_sig_digest)
- [x] Crypto additions: ripemd160, recover_pubkey, verify_sig_digest
- [x] noble-generated cross-implementation fixtures (recovery, ripemd160,
      PLC genesis + operations)

### M5 — Identity (`packages/identity`) — ✅ DONE
- [x] Minimal RFC 1035 DNS TXT client (Sockets has no record lookups):
      query builder, response parser (compression pointers, chunked TXT
      re-joining), system nameserver discovery, UDP query with timeout
- [x] HandleResolver: DNS TXT -> HTTPS well-known -> backup nameservers,
      exactly-one-`did=`-record rule, injectable dns/fetch for offline tests
- [x] IdResolver (DidResolver + HandleResolver sharing config)
- [x] resolve_identity: bidirectional verification (handle -> did -> doc
      alsoKnownAs match, case-insensitive) with IdentityMismatchError

### M6 — XRPC (`packages/xrpc`) — ✅ DONE
- [x] XRPCClient with injectable transport: get/proc calls, query param
      encoding per lexicon types (string/float/integer/boolean/datetime,
      repeating keys for arrays; ordered Vector{Pair} or sorted Dict params)
- [x] Body encoding: lex JSON, text/*, raw bytes; response parsing by
      content type (JSON -> lex values incl $bytes/$link markers, text, bytes)
- [x] XRPCError with status/error/message/headers + response-type names
- [x] Lexicon JSON serialization layer (serialize_lex/parse_lex):
      DagBytes <-> {"$bytes"} (unpadded base64), CID <-> {"$link"}
- [x] AuthSession: createSession/refreshSession; SessionClient with
      automatic 401 -> refresh -> retry-once
- [x] subscribe_url building (ws/wss) + WebSocket frame iterator with
      split_frame DAG-CBOR header/payload decoding (stream decoder)
- [ ] WebSocket auto-reconnect/backoff — deferred to M12 (firehose) where
      the full policy from @atproto/ws-client lands

### M7 — Lexicon (`packages/lexicon`) — ✅ DONE
- [x] Lexicon doc parsing/validation (defs structure, main-def placement
      rule, string formats, array/ref/union shapes); docs kept as parsed
      JSON dicts (exactly what the validators consume)
- [x] Lexicons collection: registration with doc-relative (#main) ref
      rewriting, cross-document def resolution in both #main forms
- [x] Full validator suite: primitives (boolean/integer/string with const,
      enum, bounds; minLength/maxLength count UTF-8 bytes, min/maxGraphemes
      via stdlib grapheme segmentation; all 11 string formats), bytes,
      cid-link, unknown, token, arrays, objects (required/nullable/defaults
      with lazy shallow cloning), refs, unions (open pass-through, closed
      rejection, #main matching in both directions), blobs (BlobRef values)
- [x] XRPC entry points: assertValidRecord/Params/Input/Output
- [x] BlobRef: typed + legacy JSON forms, IPLD form (empty-string CID key)
- [x] Stress test: all 407 official lexicons parse and every ref resolves

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
