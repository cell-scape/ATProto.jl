"""
    ATProto

A Julia SDK for the AT Protocol (atproto.com), the decentralized social
protocol powering Bluesky. Ported from the reference TypeScript and Go
implementations maintained by the Bluesky team, together with community
implementations.

See `ROADMAP.md` for the milestone plan. Current coverage:

- `ATProto.Syntax` — identifier and primitive syntax types: DIDs, handles,
  NSIDs, TIDs, record keys, AT-URIs, datetimes, and language tags.
- `ATProto.Crypto` — varints, multibase, multihashes, CIDs, `did:key`
  multikeys, and ECDSA (P-256 / secp256k1) via libcrypto.
"""
module ATProto

include("Syntax/Syntax.jl")
using .Syntax

include("Crypto/Crypto.jl")
using .Crypto

# Re-export module APIs at the top level.
for mod in (:Syntax, :Crypto)
    for name in names(getfield(@__MODULE__, mod); all = false)
        @eval using .$(mod): $name
        @eval export $name
    end
end

end # module
