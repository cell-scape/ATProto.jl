#= jetstream/stream.jl =#

function _build_jetstream_url(
    base_url::AbstractString;
    wanted_collections::AbstractVector = String[],
    wanted_dids::AbstractVector = String[],
    cursor::Union{Integer, Nothing} = nothing,
    max_message_size_bytes::Union{Integer, Nothing} = nothing,
    require_hello::Bool = false,
    compress::Bool = false,
)
    parts = String[]
    for col in wanted_collections
        push!(parts, "wantedCollections=" * HTTP.URIs.escapeuri(string(col)))
    end
    for did in wanted_dids
        push!(parts, "wantedDids=" * HTTP.URIs.escapeuri(string(did)))
    end
    if !isnothing(cursor)
        push!(parts, "cursor=" * string(Int64(cursor)))
    end
    if !isnothing(max_message_size_bytes)
        push!(parts, "maxMessageSizeBytes=" * string(Int(max_message_size_bytes)))
    end
    if require_hello
        push!(parts, "requireHello=true")
    end
    if compress
        push!(parts, "compress=true")
    end

    isempty(parts) && return String(base_url)
    sep = occursin('?', base_url) ? '&' : '?'
    return string(base_url, sep, join(parts, '&'))
end

"""
    save_cursor(path::AbstractString, cursor::Integer) -> String

Atomically persist a Jetstream `time_us` cursor checkpoint to `path` so a
consumer or bot can resume cleanly across restarts.
"""
function save_cursor(path::AbstractString, cursor::Integer)::String
    dir = dirname(abspath(path))
    isdir(dir) || mkpath(dir)
    tmp = string(path, ".tmp.", getpid())
    write(tmp, string(Int64(cursor), "\n"))
    mv(tmp, path; force = true)
    return String(path)
end

"""
    load_cursor(path::AbstractString) -> Union{Int64, Nothing}

Load a Jetstream `time_us` cursor previously written by [`save_cursor`](@ref).
Returns `nothing` if the file does not exist or cannot be parsed.
"""
function load_cursor(path::AbstractString)::Union{Int64, Nothing}
    isfile(path) || return nothing
    s = strip(read(path, String))
    isempty(s) && return nothing
    return tryparse(Int64, s)
end

"""
    JetstreamStream

Live streaming handle over a Bluesky Jetstream WebSocket connection backed by a
`Channel{JetstreamEvent}`.

Supports iteration (`for ev in stream`), `take!(stream)`, `isopen(stream)`,
`close(stream)`, cursor inspection via [`last_cursor`](@ref), and live filter
updates via [`update_options!`](@ref).
"""
mutable struct JetstreamStream
    const base_url::String
    const channel::Channel{JetstreamEvent}
    const stop_flag::Threads.Atomic{Bool}
    const lock::ReentrantLock
    task::Union{Task, Nothing}
    ws::Union{HTTP.WebSockets.WebSocket, Nothing}
    last_cursor::Union{Int64, Nothing}
    events_received::Int64
    reconnects::Int
end

Base.IteratorSize(::Type{JetstreamStream}) = Base.SizeUnknown()
Base.eltype(::Type{JetstreamStream}) = JetstreamEvent
Base.iterate(s::JetstreamStream) = iterate(s.channel)
Base.iterate(s::JetstreamStream, state) = iterate(s.channel, state)
Base.take!(s::JetstreamStream) = take!(s.channel)
Base.isopen(s::JetstreamStream) = isopen(s.channel) && !s.stop_flag[]

"""
    last_cursor(s::JetstreamStream) -> Union{Int64, Nothing}

Return the most recently observed Jetstream `time_us` cursor (Unix microseconds),
or `nothing` if no events have been received yet.
"""
last_cursor(s::JetstreamStream) = lock(() -> s.last_cursor, s.lock)

function Base.show(io::IO, s::JetstreamStream)
    cur = last_cursor(s)
    print(io, "JetstreamStream(url=", repr(s.base_url),
          ", open=", isopen(s),
          ", events=", lock(() -> s.events_received, s.lock),
          ", last_cursor=", cur, ")")
end

"""
    close(s::JetstreamStream) -> Nothing

Gracefully stop the Jetstream consumer task, close the underlying WebSocket
connection, and close the event channel.
"""
function Base.close(s::JetstreamStream)
    s.stop_flag[] = true
    ws = lock(s.lock) do
        w = s.ws
        s.ws = nothing
        return w
    end
    if !isnothing(ws)
        try
            close(ws)
        catch
        end
    end
    isopen(s.channel) && close(s.channel)
    return nothing
end

"""
    update_options!(s::JetstreamStream; wanted_collections=nothing, wanted_dids=nothing, max_message_size_bytes=nothing) -> Nothing

Send a live Jetstream `options_update` frame over the active WebSocket connection
to dynamically change collection/DID filters without reconnecting.
"""
function update_options!(
    s::JetstreamStream;
    wanted_collections::Union{AbstractVector, Nothing} = nothing,
    wanted_dids::Union{AbstractVector, Nothing} = nothing,
    max_message_size_bytes::Union{Integer, Nothing} = nothing,
)
    payload = Dict{String, Any}()
    if !isnothing(wanted_collections)
        payload["wantedCollections"] = String[string(c) for c in wanted_collections]
    end
    if !isnothing(wanted_dids)
        payload["wantedDids"] = String[string(d) for d in wanted_dids]
    end
    if !isnothing(max_message_size_bytes)
        payload["maxMessageSizeBytes"] = Int(max_message_size_bytes)
    end
    frame = JSON.json(Dict("type" => "options_update", "payload" => payload))

    ws = lock(() -> s.ws, s.lock)
    isnothing(ws) && throw(InvalidStateException("Jetstream WebSocket is not currently connected", :closed))
    HTTP.WebSockets.send(ws, frame)
    return nothing
end

function _sleep_interruptible(seconds::Real, stop_flag::Threads.Atomic{Bool})
    deadline = time() + seconds
    while !stop_flag[] && time() < deadline
        sleep(min(0.05, max(0.0, deadline - time())))
    end
    return nothing
end

"""
    subscribe_jetstream(; kwargs...) -> JetstreamStream
    subscribe_jetstream(f::Function; kwargs...)

Connect to a Bluesky Jetstream WebSocket endpoint and stream parsed
[`JetstreamEvent`](@ref)s into a [`JetstreamStream`](@ref).

The `do`-block form `subscribe_jetstream(; ...) do stream ... end` guarantees
that `close(stream)` is called when the block exits.

# Keyword Arguments
- `url::AbstractString = DEFAULT_JETSTREAM_URL`: Jetstream WebSocket endpoint URL.
- `wanted_collections = String[]`: Collection NSIDs or prefix wildcards (e.g. `["app.bsky.feed.post"]`).
- `wanted_dids = String[]`: Account DIDs to filter by.
- `cursor::Union{Integer, Nothing} = nothing`: Starting cursor in Unix microseconds.
- `max_message_size_bytes::Union{Integer, Nothing} = nothing`: Optional max event payload size.
- `require_hello::Bool = false`: Wait for a client `options_update` before streaming events.
- `compress::Bool = false`: Request Zstandard-compressed binary WebSocket frames (`compress=true`).
- `zstd_dictionary::Union{AbstractVector{UInt8}, AbstractString, Nothing} = nothing`: Optional
  custom Zstandard dictionary bytes or file path (e.g. Bluesky Jetstream's `zstd_dictionary`).
- `cursor_file::Union{AbstractString, Nothing} = nothing`: Optional file path to load the
  initial cursor from (when `cursor === nothing`) and periodically checkpoint `last_cursor`.
- `checkpoint_interval::Real = 5.0`: Minimum seconds between `cursor_file` writes.
- `buffer_size::Int = 1024`: Capacity of the backing `Channel{JetstreamEvent}`.
- `strict::Bool = false`: If `true`, propagate record deserialization errors instead of falling back to `UnknownObject`.
- `reconnect::Bool = true`: Automatically reconnect with exponential backoff on disconnect.
- `max_reconnects::Union{Int, Nothing} = nothing`: Maximum reconnect attempts (`nothing` for unlimited).
- `reconnect_delay::Float64 = 1.0`: Initial backoff delay in seconds.
- `max_reconnect_delay::Float64 = 30.0`: Maximum backoff delay in seconds.
- `cursor_rewind_us::Int64 = 5_000_000`: Microseconds to rewind `last_cursor` on reconnect to avoid missed events.
- `on_error = nothing`: Optional callback `(err::Exception) -> nothing` invoked on parse or connection errors.
"""
function subscribe_jetstream(;
    url::AbstractString = DEFAULT_JETSTREAM_URL,
    wanted_collections::AbstractVector = String[],
    wanted_dids::AbstractVector = String[],
    cursor::Union{Integer, Nothing} = nothing,
    max_message_size_bytes::Union{Integer, Nothing} = nothing,
    require_hello::Bool = false,
    compress::Bool = false,
    zstd_dictionary::Union{AbstractVector{UInt8}, AbstractString, Nothing} = nothing,
    cursor_file::Union{AbstractString, Nothing} = nothing,
    checkpoint_interval::Real = 5.0,
    buffer_size::Int = 1024,
    strict::Bool = false,
    reconnect::Bool = true,
    max_reconnects::Union{Integer, Nothing} = nothing,
    reconnect_delay::Real = 1.0,
    max_reconnect_delay::Real = 30.0,
    cursor_rewind_us::Integer = 5_000_000,
    on_error = nothing,
)
    cols = String[string(c) for c in wanted_collections]
    dids = String[string(d) for d in wanted_dids]
    cfile = isnothing(cursor_file) ? nothing : String(cursor_file)
    init_cursor = if !isnothing(cursor)
        Int64(cursor)
    elseif !isnothing(cfile)
        load_cursor(cfile)
    else
        nothing
    end
    max_rec = isnothing(max_reconnects) ? nothing : Int(max_reconnects)
    rewind = Int64(cursor_rewind_us)
    chk_interval = Float64(checkpoint_interval)

    dict_bytes = if isnothing(zstd_dictionary)
        nothing
    elseif zstd_dictionary isa AbstractString
        read(zstd_dictionary)
    else
        Vector{UInt8}(zstd_dictionary)
    end
    decompressor = (compress || !isnothing(dict_bytes)) ? ZstdDecompressor(; dictionary = dict_bytes) : nothing

    stream = JetstreamStream(
        String(url),
        Channel{JetstreamEvent}(buffer_size),
        Threads.Atomic{Bool}(false),
        ReentrantLock(),
        nothing,
        nothing,
        init_cursor,
        0,
        0,
    )

    stream.task = @async begin
        delay = Float64(reconnect_delay)
        attempts = 0
        last_checkpoint = time()
        try
            while !stream.stop_flag[] && isopen(stream.channel)
                cur = lock(() -> stream.last_cursor, stream.lock)
                connect_cursor = if attempts == 0
                    init_cursor
                elseif !isnothing(cur)
                    max(Int64(0), cur - rewind)
                else
                    nothing
                end
                full_url = _build_jetstream_url(
                    stream.base_url;
                    wanted_collections = cols,
                    wanted_dids = dids,
                    cursor = connect_cursor,
                    max_message_size_bytes = max_message_size_bytes,
                    require_hello = require_hello,
                    compress = compress,
                )

                try
                    HTTP.WebSockets.open(full_url; suppress_close_error = true) do ws
                        lock(stream.lock) do
                            stream.ws = ws
                        end
                        # Reset backoff once connected
                        delay = Float64(reconnect_delay)
                        try
                            for msg in ws
                                stream.stop_flag[] && break
                                payload = try
                                    if msg isa AbstractVector{UInt8} && (!isnothing(decompressor) || _is_zstd_frame(msg))
                                        dec = isnothing(decompressor) ? ZstdDecompressor() : decompressor
                                        zstd_decompress(dec, msg)
                                    else
                                        msg
                                    end
                                catch e
                                    isnothing(on_error) || on_error(e)
                                    continue
                                end
                                ev = try
                                    parse_jetstream_event(payload; strict = strict)
                                catch e
                                    isnothing(on_error) || on_error(e)
                                    continue
                                end
                                lock(stream.lock) do
                                    if !isnothing(ev.time_us)
                                        stream.last_cursor = ev.time_us
                                    end
                                    stream.events_received += 1
                                end
                                if !isnothing(cfile) && !isnothing(ev.time_us) && (time() - last_checkpoint >= chk_interval)
                                    try
                                        save_cursor(cfile, ev.time_us)
                                        last_checkpoint = time()
                                    catch e
                                        isnothing(on_error) || on_error(e)
                                    end
                                end
                                if !stream.stop_flag[] && isopen(stream.channel)
                                    try
                                        put!(stream.channel, ev)
                                    catch
                                        # Channel closed while pushing
                                        break
                                    end
                                else
                                    break
                                end
                            end
                        finally
                            lock(stream.lock) do
                                stream.ws = nothing
                            end
                        end
                    end
                catch e
                    if !stream.stop_flag[]
                        isnothing(on_error) || on_error(e)
                    end
                end

                (stream.stop_flag[] || !isopen(stream.channel) || !reconnect) && break
                attempts += 1
                lock(stream.lock) do
                    stream.reconnects = attempts
                end
                if !isnothing(max_rec) && attempts > max_rec
                    break
                end
                _sleep_interruptible(delay, stream.stop_flag)
                delay = min(Float64(max_reconnect_delay), delay * 2.0)
            end
        finally
            if !isnothing(cfile)
                final_cur = lock(() -> stream.last_cursor, stream.lock)
                if !isnothing(final_cur)
                    try
                        save_cursor(cfile, final_cur)
                    catch
                    end
                end
            end
            isopen(stream.channel) && close(stream.channel)
        end
    end

    return stream
end

function subscribe_jetstream(f::Function; kwargs...)
    stream = subscribe_jetstream(; kwargs...)
    try
        return f(stream)
    finally
        close(stream)
    end
end
