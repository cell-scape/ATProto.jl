# WebSocket-based XRPC subscriptions (firehose / jetstream transport).
# Frame semantics (repo commit ops, etc.) are decoded in later milestones;
# this layer owns connection setup, URL building, and frame iteration.

"""
    subscribe_url(service, nsid; params=Dict(), param_types=Dict()) -> String

Build the WebSocket URL for an XRPC subscription endpoint
(`ws(s)://<service>/xrpc/<nsid>`).
"""
function subscribe_url(service::AbstractString, nsid::AbstractString;
                       params = Dict{String,Any}(),
                       param_types::Dict = Dict{String,Any}())::String
    base = rstrip(String(service), '/')
    ws_base = startswith(base, "https://") ? "wss://" * base[length("https://")+1:end] :
              startswith(base, "http://") ? "ws://" * base[length("http://")+1:end] :
              "wss://" * base
    return ws_base * construct_method_call_url(nsid, params; param_types)
end

"""
    subscribe(service, nsid; params=Dict(), headers=(), on_connect=nothing)

Open an XRPC subscription WebSocket and return an iterator of raw binary
frames (`Vector{UInt8}`), suitable for `for frame in subscribe(...)` loops.
The iterator ends when the socket closes; connection errors propagate.

`on_connect(ws)` — if provided — runs after the connection opens (e.g. to
check the server's ack).
"""
function subscribe(service::AbstractString, nsid::AbstractString;
                   params = Dict{String,Any}(), headers = (),
                   on_connect = nothing)
    url = subscribe_url(service, nsid; params)
    ws = HTTP.WebSockets.open(url; headers = headers)
    on_connect !== nothing && on_connect(ws)
    return _FrameIterator(ws)
end

struct _FrameIterator
    ws::HTTP.WebSockets.WebSocket
end

function Base.iterate(it::_FrameIterator, state = nothing)
    # receive blocks until a message arrives; on close/error the iteration ends
    frame = try
        HTTP.WebSockets.receive(it.ws)  # binary message bytes
    catch
        return nothing
    end
    return (frame, nothing)
end

"""
    split_frame(frame) -> (header::Dict, payload::Vector{UInt8})

Split a subscription frame into its DAG-CBOR header map and the remaining
payload bytes.
"""
function split_frame(frame::AbstractVector{UInt8})
    io = IOBuffer(copy(frame))
    header = _decode_one_value!(io)
    consumed = position(io)
    payload = UInt8[frame[i] for i in (consumed+1):length(frame)]
    return (header = header, payload = payload)
end

# Decode a single DAG-CBOR value from an IOBuffer, leaving the rest unread.
# (The DagCbor module only exposes whole-buffer decoding.)
function _decode_one_value!(io::IOBuffer)
    ib = Base.read(io, UInt8)
    major = ib >> 5
    info = ib & 0x1f
    major == 0x07 && error("simple values unsupported in frame headers")
    arg = info < 24 ? UInt64(info) : _read_arg!(io, info)
    if major == 0x00
        return arg <= typemax(Int64) ? Int64(arg) : arg
    elseif major == 0x01
        return -1 - reinterpret(Int64, arg)
    elseif major == 0x02 || major == 0x03
        buf = Base.Vector{UInt8}(undef, Int(arg))
        readbytes!(io, buf) == Int(arg) || error("truncated frame header")
        s = String(buf)
        return major == 0x03 ? s : DagBytes(buf)
    elseif major == 0x04
        return Any[_decode_one_value!(io) for _ in 1:Int(arg)]
    elseif major == 0x05
        out = Dict{String,Any}()
        for _ in 1:Int(arg)
            k = _decode_one_value!(io)
            k isa AbstractString || error("frame header keys must be strings")
            out[String(k)] = _decode_one_value!(io)
        end
        return out
    elseif major == 0x06
        arg == 42 || error("unsupported tag in frame header")
        inner = _decode_one_value!(io)
        inner isa DagBytes || error("CID frame header must be bytes")
        return cid_from_bytes(inner.bytes[2:end])
    end
    error("invalid major type in frame header")
end

function _read_arg!(io::IOBuffer, info::UInt8)::UInt64
    info == 0x18 && return _be(io, 1)
    info == 0x19 && return _be(io, 2)
    info == 0x1a && return _be(io, 4)
    info == 0x1b && return _be(io, 8)
    info == 0x1f && error("indefinite lengths unsupported in frames")
    error("reserved additional info in frame header")
end

function _be(io::IOBuffer, n::Int)::UInt64
    v = UInt64(0)
    for _ in 1:n
        v = (v << 8) | Base.read(io, UInt8)
    end
    return v
end

