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

include("DagCbor/DagCbor.jl")
using .DagCbor

include("DID/DID.jl")
using .DID

include("Identity/Identity.jl")
using .Identity

include("XRPC/XRPC.jl")
using .XRPC

include("Lexicon/Lexicon.jl")
using .Lexicon

include("Repo/Repo.jl")
using .Repo

include("API/API.jl")
include("RichText/RichText.jl")
using .RichText
using .API: Agent, SessionAgent, login, client_of, service_url, did_of,
    handle_of, session_of, resolve_handle, upload_blob, put_record,
    delete_record, create_record, get_record, create_post, delete_post,
    OFFICIAL_LEXICONS

export Agent, SessionAgent, login, client_of, service_url, did_of, handle_of,
    session_of, resolve_handle, upload_blob, put_record, delete_record,
    create_record, get_record, create_post, delete_post, OFFICIAL_LEXICONS

# Re-export module APIs at the top level.
for mod in (:Syntax, :Crypto, :DagCbor, :DID, :Identity, :XRPC, :Lexicon, :Repo, :RichText)
    for name in names(getfield(@__MODULE__, mod); all = false)
        @eval using .$(mod): $name
        @eval export $name
    end
end

end # module
