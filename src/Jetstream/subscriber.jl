# WebSocket subscriber with reconnect + backoff + cursor management.
# Port of `jetstream/client.go` + `jetstream/live.go` reconnection behavior.

"""
    jetstream_subscribe(f, url; cursor=nothing, wanted_collections=nothing,
                        wanted_dids=nothing, max_reconnects=10, backoff_min=1.0,
                        backoff_max=30.0, compression=nothing)

Subscribe to a jetstream/firehose WebSocket, calling `f(event)` for each
decoded event. Automatically reconnects with exponential backoff (capped),
resuming from the last seen cursor.

Filters:
- `wanted_collections`: only these NSIDs (e.g. `["app.bsky.feed.post"]`)
- `wanted_dids`: only these DIDs

The loop runs until the callback returns `:stop`, `max_reconnects` is
exhausted, or the connection closes cleanly. Returns the last cursor seen.
"""
function jetstream_subscribe(f::Function, url::AbstractString;
                             cursor::Union{Integer,Nothing} = nothing,
                             wanted_collections = nothing,
                             wanted_dids = nothing,
                             max_reconnects::Int = 10,
                             backoff_min::Real = 1.0,
                             backoff_max::Real = 30.0)::Union{Int,Nothing}
    params = String[]
    cursor !== nothing && push!(params, "cursor=" * string(cursor))
    wanted_collections !== nothing && !isempty(wanted_collections) &&
        append!(params, ["wantedCollections=" * HTTP.URIs.escapeuri(c)
                         for c in wanted_collections])
    wanted_dids !== nothing && !isempty(wanted_dids) &&
        append!(params, ["wantedDids=" * HTTP.URIs.escapeuri(d)
                         for d in wanted_dids])

    full_url = String(url)
    if !isempty(params)
        sep = occursin('?', full_url) ? '&' : '?'
        full_url *= sep * join(params, '&')
    end

    last_cursor = Ref{Union{Int,Nothing}}(cursor)
    reconnects = 0
    backoff = Float64(backoff_min)

    while reconnects <= max_reconnects
        try
            ws = HTTP.WebSockets.open(full_url)
            try
                while true
                    frame = HTTP.WebSockets.receive(ws)
                    event = _parse_jetstream_frame(frame)
                    if event !== nothing
                        seq = get(event, "cursor", nothing)
                        seq isa Integer && (last_cursor[] = Int(seq))
                        action = f(event)
                        action === :stop && return last_cursor[]
                    end
                end
            catch err
                err isa HTTP.WebSockets.WebSocketError && rethrow()
                # connection dropped: reconnect
            finally
                try close(ws) catch end
            end
            # clean close (server hung up): reconnect with backoff
            reconnects += 1
            if reconnects <= max_reconnects
                sleep(backoff)
                backoff = min(backoff * 2, Float64(backoff_max))
                # rebuild URL with updated cursor
                if last_cursor[] !== nothing
                    full_url = _replace_param(String(url), "cursor", string(last_cursor[]))
                end
            end
        catch err
            err isa HTTP.WebSockets.WebSocketError || rethrow()
            # connection error: reconnect with backoff
            reconnects += 1
            if reconnects <= max_reconnects
                sleep(backoff)
                backoff = min(backoff * 2, Float64(backoff_max))
                if last_cursor[] !== nothing
                    full_url = _replace_param(String(url), "cursor", string(last_cursor[]))
                end
            end
        end
    end
    return last_cursor[]
end

"Parse a jetstream JSON frame (or a firehose DAG-CBOR frame)."
function _parse_jetstream_frame(frame)
    frame isa AbstractString && return JSON.parse(String(frame))
    frame isa AbstractVector{UInt8} || return nothing
    # try JSON first (jetstream serves JSON)
    try
        return JSON.parse(String(copy(frame)))
    catch
    end
    # fall back to firehose DAG-CBOR
    ev = parse_firehose_frame(frame)
    ev isa FirehoseEvent && return firehose_to_jetstream_json(ev)
    return ev
end

"Replace or add a query parameter in a URL."
function _replace_param(url::AbstractString, key::String, value::String)::String
    # split off query
    base, query = if (i = findfirst('?', url)) === nothing
        String(url), ""
    else
        url[1:prevind(url, i)], String(url[nextind(url, i):end])
    end
    # rebuild query without the key
    parts = filter(!isempty, split(query, '&'))
    kept = String[]
    for p in parts
        kv = split(p, '='; limit = 2)
        if String(first(kv)) != key
            push!(kept, p)
        end
    end
    push!(kept, string(key, "=", value))
    return string(base, "?", join(kept, '&'))
end
