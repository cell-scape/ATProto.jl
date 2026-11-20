```@meta
CurrentModule = ATProto
DocTestSetup = quote
    using ATProto
end
```

# Syntax Primitives

`ATProto.Syntax` implements the AT Protocol identifier and data syntax specifications
with strict ASCII, single-pass zero-allocation validators (statically verified with
`AllocCheck.jl`) and immutable value types integrating with `Base.parse`, `Base.tryparse`,
`JSON.jl`, and `StructUtils.jl`.

## Compile-Time String Macros

All syntax types expose compile-time validated string literals:

```jldoctest
julia> handle"Bsky.App"
Handle("bsky.app")

julia> did"did:plc:z72i7hdynmk6r22z27h6tvur"
DID("did:plc:z72i7hdynmk6r22z27h6tvur")

julia> nsid"app.bsky.feed.post"
NSID("app.bsky.feed.post")

julia> rkey"self"
RecordKey("self")

julia> tid"3jui7kd54zh2y"
TID("3jui7kd54zh2y")

julia> at"at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y"
AtUri("at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y")
```

## Reference

```@autodocs
Modules = [ATProto.Syntax]
Order = [:type, :macro, :function, :constant]
```
