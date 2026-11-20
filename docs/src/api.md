```@meta
CurrentModule = ATProto
DocTestSetup = quote
    using ATProto
end
```

# Lexicon API & Code Generation

`ATProto.API` contains the core AT Protocol data-model runtime plus ahead-of-time
generated Julia types from all 237 vendored Lexicon schemas in `lexicons/`.

## Dual Access Styles

Generated types are available both via flat canonical names in `ATProto.API` and via
hierarchical NSID namespace modules (`App`, `Chat`, `Com`, `Tools`):

```jldoctest
julia> API.App.Bsky.Feed.Post.Main === API.AppBskyFeedPost
true

julia> lexicon_type(API.AppBskyFeedPost)
"app.bsky.feed.post"

julia> record_key_type(API.AppBskyFeedPost)
"tid"

julia> API.Com.Atproto.Repo.CreateRecord.ENDPOINT.nsid
NSID("com.atproto.repo.createRecord")
```

## Regenerating Lexicons

After updating JSON schemas under `lexicons/`, regenerate `src/api/generated/`:

```bash
julia --project=. scripts/generate_lexicons.jl
```

## Core API Reference

```@docs
LexiconModel
LexiconObject
LexiconRecord
LexiconMessage
LexiconParams
LexiconInput
LexiconOutput
CIDLink
ATBytes
BlobRef
UnknownObject
EndpointError
QueryEndpoint
ProcedureEndpoint
SubscriptionEndpoint
lexicon_type
needs_type_tag
record_key_type
LEXICON_TYPES
LEXICON_ENDPOINTS
LEXICON_TOKENS
```
