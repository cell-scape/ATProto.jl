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

## Zstandard Compression & Cursor Checkpointing

Enable `compress = true` (optionally supplying Bluesky Jetstream's custom dictionary via
`zstd_dictionary`) to reduce wire bandwidth by ~70%, and pass `cursor_file` to
automatically persist and resume your stream cursor across process restarts:

```julia
subscribe_jetstream(
    wanted_collections = ["app.bsky.feed.post"],
    compress = true,
    zstd_dictionary = "path/to/zstd_dictionary",
    cursor_file = "jetstream.cursor",
) do stream
    for ev in stream
        ...
    end
end
```

## Reference

```@autodocs
Modules = [ATProto.Jetstream]
Order = [:type, :function, :constant]
```
