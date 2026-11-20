```@meta
CurrentModule = ATProto
```

# Jetstream Streaming

`ATProto.Jetstream` streams real-time Bluesky JSON events over WebSockets into a
Julia `Channel{JetstreamEvent}`, deserializing known record types (posts, likes,
follows, etc.) directly into generated `ATProto.API` structs while gracefully falling
back to `UnknownObject` for unknown or malformed third-party records.

## Example

```julia
using ATProto

subscribe_jetstream(
    wanted_collections = ["app.bsky.feed.post"],
    cursor_rewind_us = 5_000_000,
) do stream
    for ev in Iterators.take(stream, 20)
        if ev isa JetstreamCommitEvent && ev.operation === :create && ev.record isa API.AppBskyFeedPost
            println(aturi(ev), " => ", ev.record.text)
        end
    end
end
```

## Reference

```@autodocs
Modules = [ATProto.Jetstream]
Order = [:type, :function, :constant]
```
