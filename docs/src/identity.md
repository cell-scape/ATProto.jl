```@meta
CurrentModule = ATProto
```

# Identity Resolution

`ATProto.Identity` provides standalone AT Protocol DID and handle resolution with
bidirectional verification and thread-safe TTL caching:

- **`did:plc`** resolution via `https://plc.directory`
- **`did:web`** resolution via `/.well-known/did.json` (enforcing ATProto hostname-only rules)
- **Handle resolution** via DNS TXT (`_atproto.<handle>`, using DNS-over-HTTPS by default
  or a custom `dns_resolver` callback) with HTTPS `/.well-known/atproto-did` fallback
- **Bidirectional verification** (`verify_handle`, `resolve_identity`) ensuring both
  handle → DID and DID document `alsoKnownAs` → handle agree

## Example

```julia
using ATProto

# Resolve and bidirectionally verify an account
id = resolve_identity(handle"bsky.app")
id.did              # DID("did:plc:z72i7hdynmk6r22z27h6tvur")
id.handle_verified  # true
id.pds              # "https://bsky.social" (or user's personal PDS)

# Custom resolver with TTL caching or custom DNS callback
resolver = IdentityResolver(cache_ttl = 600.0)
doc = resolve_did(resolver, did"did:plc:z72i7hdynmk6r22z27h6tvur")
pds_endpoint(doc)
signing_key(doc)
```

## Reference

```@autodocs
Modules = [ATProto.Identity]
Order = [:type, :function, :constant]
```
