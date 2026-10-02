"""
    ATProto

A Julia SDK for the AT Protocol (atproto.com), the decentralized social
protocol powering Bluesky. Ported from the reference TypeScript and Go
implementations maintained by the Bluesky team, together with community
implementations.

See `ROADMAP.md` for the milestone plan. Current coverage:

- `ATProto.Syntax` — identifier and primitive syntax types: DIDs, handles,
  NSIDs, TIDs, record keys, AT-URIs, datetimes, and language tags.
"""
module ATProto

include("Syntax/Syntax.jl")
using .Syntax

# Re-export the full Syntax API at the top level.
for name in names(Syntax; all = false)
    @eval using .Syntax: $name
    @eval export $name
end

end # module
