# Firehose event types + frame decoding.
# Port of `indigo/events/events.go` (XRPCStreamEvent) + jetstream's Event.

"""
    FirehoseEvent

Abstract supertype of all firehose events.
"""
abstract type FirehoseEvent end

"""
    CommitEvent

A `#commit` event: a record create, update, or delete. `record` holds the
decoded record; `record_bytes` the canonical DAG-CBOR. Both are `nothing`
for deletes.
"""
struct CommitEvent <: FirehoseEvent
    seq::Int
    rev::String
    did::String
    operation::Symbol       # :create, :update, :delete
    collection::String
    rkey::String
    record::Union{Dict{String,Any},Nothing}
    record_bytes::Union{Vector{UInt8},Nothing}
    cid::Union{CID,Nothing}
    prev::Union{String,Nothing}
end

"""
    IdentityEvent

An `#identity` event: a handle or DID-document change.
"""
struct IdentityEvent <: FirehoseEvent
    seq::Int
    did::String
    handle::Union{String,Nothing}
    time::String
end

"""
    AccountEvent

An `#account` event: a hosting-status change (active/suspended/deleted).
"""
struct AccountEvent <: FirehoseEvent
    seq::Int
    did::String
    active::Bool
    status::Union{String,Nothing}
    time::String
end

"""
    SyncEvent

A `#sync` event: the upstream signaled a repo divergence requiring resync.
"""
struct SyncEvent <: FirehoseEvent
    seq::Int
    did::String
    rev::String
    time::String
end

# --- frame decoding ---------------------------------------------------------------

# Firehose frame headers (DAG-CBOR):
#   op=1 → message with "t" (type) + body
#   op=2 → timeline info (ack / status update)
const OP_MESSAGE = 1
const OP_INFO = 2

"""
    parse_firehose_frame(frame::Vector{UInt8}) -> Union{FirehoseEvent, NamedTuple, Nothing}

Decode one binary firehose frame (from `com.atproto.sync.subscribeRepos` or
`com.atproto.label.subscribeLabels`) into a typed event. Returns `nothing`
for unrecognized frames. For `#info` frames, returns
`(op = 2, status = "...")`.
"""
function parse_firehose_frame(frame::AbstractVector{UInt8})
    parts = split_frame(frame)
    header = parts.header
    header isa AbstractDict || return nothing
    op = get(header, "op", nothing)
    op isa Integer || return nothing

    if op == OP_INFO
        return (op = 2, status = String(get(header, "status", "")))
    end
    op == OP_MESSAGE || return nothing

    msg_type = get(header, "t", nothing)
    msg_type isa AbstractString || return nothing
    body = _decode_body(parts.payload)

    if msg_type == "#commit"
        return _parse_commit(body)
    elseif msg_type == "#identity"
        return _parse_identity(body)
    elseif msg_type == "#account"
        return _parse_account(body)
    elseif msg_type == "#sync"
        return _parse_sync(body)
    end
    return nothing  # unknown message type
end

"Decode the payload bytes (DAG-CBOR) into a Dict, or nothing on failure."
_decode_body(payload::Vector{UInt8}) = try
    isempty(payload) ? Dict{String,Any}() : dag_cbor_decode(payload)
catch
    nothing
end

function _parse_commit(body)
    body isa AbstractDict || return nothing
    seq = _int_or(body, "seq", 0)
    rev = _str_or(body, "rev", "")
    did = _str_or(body, "did", "")
    prev = get(body, "prev", nothing)
    prev_str = prev isa CID ? string(prev) :
               prev isa AbstractString ? String(prev) : nothing

    # ops: a list of repo operations
    ops = get(body, "ops", nothing)
    ops isa AbstractVector && !isempty(ops) || return nothing
    first_op = ops[1]
    first_op isa AbstractDict || return nothing

    action = get(first_op, "action", nothing)
    action_str = action isa AbstractString ? String(action) : ""

    if action_str == "delete"
        return CommitEvent(seq, rev, did, :delete,
                           _str_or(first_op, "collection", ""),
                           _str_or(first_op, "rkey", ""),
                           nothing, nothing, nothing, prev_str)
    end

    # create / update: payload is a CID to the record block
    cid = get(first_op, "cid", nothing)
    record_cid = cid isa CID ? cid :
                 cid isa AbstractString ? cid_parse(String(cid)) : nothing

    # path is "collection/rkey" for create/update
    path = _str_or(first_op, "path", "")
    path_parts = split(path, '/'; limit = 2)
    collection = length(path_parts) == 2 ? String(path_parts[1]) : ""
    rkey = length(path_parts) == 2 ? String(path_parts[2]) : ""

    # the record itself is in the blocks CAR — for now, record_bytes is nothing
    # (full CAR block extraction needs the full event pipeline; jetstream
    # subscribers get the record inline)
    return CommitEvent(seq, rev, did, Symbol(action_str),
                       collection, rkey,
                       nothing, nothing, record_cid, prev_str)
end

function _parse_identity(body)
    body isa AbstractDict || return nothing
    handle = get(body, "handle", nothing)
    return IdentityEvent(
        _int_or(body, "seq", 0),
        _str_or(body, "did", ""),
        handle === nothing || handle === false ? nothing : String(handle),
        _str_or(body, "time", ""),
    )
end

function _parse_account(body)
    body isa AbstractDict || return nothing
    active = get(body, "active", true) === true
    status = get(body, "status", nothing)
    return AccountEvent(
        _int_or(body, "seq", 0),
        _str_or(body, "did", ""),
        active,
        status isa AbstractString ? String(status) : nothing,
        _str_or(body, "time", ""),
    )
end

function _parse_sync(body)
    body isa AbstractDict || return nothing
    return SyncEvent(
        _int_or(body, "seq", 0),
        _str_or(body, "did", ""),
        _str_or(body, "rev", ""),
        _str_or(body, "time", ""),
    )
end

@inline _int_or(d, k, default) = begin
    v = get(d, k, nothing)
    v isa Integer ? Int(v) : default
end

@inline _str_or(d, k, default) = begin
    v = get(d, k, nothing)
    v isa AbstractString ? String(v) : default
end

# --- jetstream JSON conversion ------------------------------------------------

"""
    firehose_to_jetstream_json(event::FirehoseEvent) -> Dict

Convert a firehose event to the Jetstream JSON wire format (the shape
`jetstream` serves over its WebSocket).
"""
function firehose_to_jetstream_json(ev::CommitEvent)::Dict{String,Any}
    commit = Dict{String,Any}(
        "operation" => String(ev.operation),
        "collection" => ev.collection,
        "rkey" => ev.rkey,
        "rev" => ev.rev,
    )
    ev.cid !== nothing && (commit["cid"] = string(ev.cid))
    ev.record !== nothing && (commit["record"] = ev.record)
    return Dict{String,Any}(
        "did" => ev.did,
        "cursor" => ev.seq,
        "kind" => "commit",
        "commit" => commit,
    )
end

function firehose_to_jetstream_json(ev::IdentityEvent)::Dict{String,Any}
    identity = Dict{String,Any}("did" => ev.did, "seq" => ev.seq, "time" => ev.time)
    ev.handle !== nothing && (identity["handle"] = ev.handle)
    return Dict{String,Any}(
        "did" => ev.did,
        "cursor" => ev.seq,
        "kind" => "identity",
        "identity" => identity,
    )
end

function firehose_to_jetstream_json(ev::AccountEvent)::Dict{String,Any}
    account = Dict{String,Any}("did" => ev.did, "seq" => ev.seq,
                               "time" => ev.time, "active" => ev.active)
    ev.status !== nothing && (account["status"] = ev.status)
    return Dict{String,Any}(
        "did" => ev.did,
        "cursor" => ev.seq,
        "kind" => "account",
        "account" => account,
    )
end

function firehose_to_jetstream_json(ev::SyncEvent)::Dict{String,Any}
    sync = Dict{String,Any}("did" => ev.did, "seq" => ev.seq,
                            "time" => ev.time, "rev" => ev.rev)
    return Dict{String,Any}(
        "did" => ev.did,
        "cursor" => ev.seq,
        "kind" => "sync",
        "sync" => sync,
    )
end
