#= jetstream/types.jl =#

"""
    DEFAULT_JETSTREAM_URL

Default public Bluesky Jetstream WebSocket endpoint.
"""
const DEFAULT_JETSTREAM_URL = "wss://jetstream2.us-east.bsky.network/subscribe"

"""
    JETSTREAM_URLS

Tuple of official Bluesky public Jetstream WebSocket endpoints across US regions.
"""
const JETSTREAM_URLS = (
    "wss://jetstream1.us-east.bsky.network/subscribe",
    "wss://jetstream2.us-east.bsky.network/subscribe",
    "wss://jetstream1.us-west.bsky.network/subscribe",
    "wss://jetstream2.us-west.bsky.network/subscribe",
)

"""
    JetstreamEvent

Abstract base type for events received from a Bluesky Jetstream WebSocket stream.
Concrete subtypes are [`JetstreamCommitEvent`](@ref), [`JetstreamIdentityEvent`](@ref),
[`JetstreamAccountEvent`](@ref), and [`JetstreamUnknownEvent`](@ref).
"""
abstract type JetstreamEvent end

"""
    JetstreamCommitEvent <: JetstreamEvent

Repository record mutation (`:create`, `:update`, or `:delete`) emitted by Jetstream.

When the committed record carries a recognized `"\$type"` (e.g. `app.bsky.feed.post`),
`record` is deserialized directly into the generated `ATProto.API` struct; otherwise
it falls back to [`UnknownObject`](@ref) (or `nothing` for `:delete` operations).
"""
struct JetstreamCommitEvent <: JetstreamEvent
    did::DID
    time_us::Int64
    rev::String
    operation::Symbol
    collection::NSID
    rkey::RecordKey
    record::Union{LexiconObject, Nothing}
    cid::Union{String, Nothing}
end

"""
    aturi(ev::JetstreamCommitEvent) -> AtUri

Construct the [`AtUri`](@ref) (`at://<did>/<collection>/<rkey>`) addressed by `ev`.
"""
aturi(ev::JetstreamCommitEvent) = AtUri(ev.did; collection = ev.collection, rkey = ev.rkey)

"""
    JetstreamIdentityEvent <: JetstreamEvent

Identity update event (e.g. handle change or DID document rotation) emitted by Jetstream.
"""
struct JetstreamIdentityEvent <: JetstreamEvent
    did::DID
    time_us::Int64
    handle::Union{Handle, Nothing}
    seq::Union{Int64, Nothing}
    time::Union{String, Nothing}
end

"""
    JetstreamAccountEvent <: JetstreamEvent

Account status change event (active/inactive, takedown, suspension, deactivation)
emitted by Jetstream.
"""
struct JetstreamAccountEvent <: JetstreamEvent
    did::DID
    time_us::Int64
    active::Bool
    seq::Union{Int64, Nothing}
    time::Union{String, Nothing}
    status::Union{String, Nothing}
end

"""
    JetstreamUnknownEvent <: JetstreamEvent

Forward-compatible fallback for unrecognized Jetstream event kinds.
"""
struct JetstreamUnknownEvent <: JetstreamEvent
    did::Union{DID, Nothing}
    time_us::Union{Int64, Nothing}
    kind::String
    raw::Dict{String, Any}
end

function Base.:(==)(a::JetstreamUnknownEvent, b::JetstreamUnknownEvent)
    return a.did == b.did && a.time_us == b.time_us && a.kind == b.kind && a.raw == b.raw
end

function Base.hash(a::JetstreamUnknownEvent, h::UInt)
    return hash(a.raw, hash(a.kind, hash(a.time_us, hash(a.did, hash(:JetstreamUnknownEvent, h)))))
end

# Internal single-pass JSON deserialization envelopes (zero intermediate Dict allocations on hot path).
abstract type _JetstreamRaw <: LexiconModel end

Base.@kwdef struct _RawCommit <: _JetstreamRaw
    rev::String = ""
    operation::String = ""
    collection::String = ""
    rkey::String = ""
    record::Union{LexiconObject, Nothing} = nothing
    cid::Union{String, Nothing} = nothing
end

Base.@kwdef struct _RawCommitLoose <: _JetstreamRaw
    rev::String = ""
    operation::String = ""
    collection::String = ""
    rkey::String = ""
    record::Union{UnknownObject, Nothing} = nothing
    cid::Union{String, Nothing} = nothing
end

Base.@kwdef struct _RawIdentity <: _JetstreamRaw
    did::Union{String, Nothing} = nothing
    handle::Union{String, Nothing} = nothing
    seq::Union{Int64, Nothing} = nothing
    time::Union{String, Nothing} = nothing
end

Base.@kwdef struct _RawAccount <: _JetstreamRaw
    active::Bool = false
    did::Union{String, Nothing} = nothing
    seq::Union{Int64, Nothing} = nothing
    time::Union{String, Nothing} = nothing
    status::Union{String, Nothing} = nothing
end

Base.@kwdef struct _RawJetstreamEnvelope <: _JetstreamRaw
    did::Union{String, Nothing} = nothing
    time_us::Union{Int64, Nothing} = nothing
    kind::String = ""
    commit::Union{_RawCommit, Nothing} = nothing
    identity::Union{_RawIdentity, Nothing} = nothing
    account::Union{_RawAccount, Nothing} = nothing
end

Base.@kwdef struct _RawJetstreamEnvelopeLoose <: _JetstreamRaw
    did::Union{String, Nothing} = nothing
    time_us::Union{Int64, Nothing} = nothing
    kind::String = ""
    commit::Union{_RawCommitLoose, Nothing} = nothing
    identity::Union{_RawIdentity, Nothing} = nothing
    account::Union{_RawAccount, Nothing} = nothing
end

function _parse_operation(op::String)
    op == "create" && return :create
    op == "update" && return :update
    op == "delete" && return :delete
    return Symbol(op)
end

function _envelope_to_event(env, raw_json::Union{String, Vector{UInt8}})
    kind = env.kind
    if kind == "commit"
        c = env.commit
        isnothing(c) && throw(ArgumentError("Jetstream 'commit' event missing 'commit' payload"))
        isnothing(env.did) && throw(ArgumentError("Jetstream 'commit' event missing 'did'"))
        isnothing(env.time_us) && throw(ArgumentError("Jetstream 'commit' event missing 'time_us'"))
        return JetstreamCommitEvent(
            DID(env.did),
            env.time_us,
            c.rev,
            _parse_operation(c.operation),
            NSID(c.collection),
            RecordKey(c.rkey),
            c.record,
            c.cid,
        )
    elseif kind == "identity"
        id = env.identity
        isnothing(id) && throw(ArgumentError("Jetstream 'identity' event missing 'identity' payload"))
        did_s = isnothing(env.did) ? id.did : env.did
        isnothing(did_s) && throw(ArgumentError("Jetstream 'identity' event missing 'did'"))
        isnothing(env.time_us) && throw(ArgumentError("Jetstream 'identity' event missing 'time_us'"))
        h = isnothing(id.handle) ? nothing : tryparse(Handle, id.handle)
        return JetstreamIdentityEvent(DID(did_s), env.time_us, h, id.seq, id.time)
    elseif kind == "account"
        acc = env.account
        isnothing(acc) && throw(ArgumentError("Jetstream 'account' event missing 'account' payload"))
        did_s = isnothing(env.did) ? acc.did : env.did
        isnothing(did_s) && throw(ArgumentError("Jetstream 'account' event missing 'did'"))
        isnothing(env.time_us) && throw(ArgumentError("Jetstream 'account' event missing 'time_us'"))
        return JetstreamAccountEvent(DID(did_s), env.time_us, acc.active, acc.seq, acc.time, acc.status)
    else
        raw = JSON.parse(raw_json, Dict{String, Any})
        did = isnothing(env.did) ? nothing : tryparse(DID, env.did)
        return JetstreamUnknownEvent(did, env.time_us, kind, raw)
    end
end

"""
    parse_jetstream_event(msg; strict::Bool=false) -> JetstreamEvent

Parse a single JSON text or byte frame from Jetstream into a typed
[`JetstreamEvent`](@ref).

When `strict=false` (default), if a committed record contains fields that fail
strict Lexicon/Syntax deserialization (common with third-party or legacy records
on the live firehose), the commit falls back to preserving `record` as an
[`UnknownObject`](@ref) rather than throwing.
"""
function parse_jetstream_event(msg::Union{AbstractString, AbstractVector{UInt8}}; strict::Bool = false)
    buf = msg isa String ? msg : (msg isa AbstractString ? String(msg) : Vector{UInt8}(msg))
    if strict
        env = JSON.parse(buf, _RawJetstreamEnvelope)
        return _envelope_to_event(env, buf)
    end

    try
        env = JSON.parse(buf, _RawJetstreamEnvelope)
        return _envelope_to_event(env, buf)
    catch e
        if e isa SyntaxError || e isa MethodError || e isa ArgumentError || e isa TypeError
            # Fallback: keep envelope typed while preserving the malformed record as UnknownObject.
            env = JSON.parse(buf, _RawJetstreamEnvelopeLoose)
            return _envelope_to_event(env, buf)
        end
        rethrow()
    end
end
