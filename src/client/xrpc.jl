#= client/xrpc.jl =#

function _push_query_param!(parts::Vector{String}, key::String, val)
    isnothing(val) && return nothing
    ek = HTTP.URIs.escapeuri(key)
    if val isa AbstractVector
        for item in val
            isnothing(item) && continue
            push!(parts, string(ek, '=', HTTP.URIs.escapeuri(_param_value_string(item))))
        end
    else
        push!(parts, string(ek, '=', HTTP.URIs.escapeuri(_param_value_string(val))))
    end
    return nothing
end

_param_value_string(v::Bool) = v ? "true" : "false"
_param_value_string(v) = string(v)

function _encode_query_params(::Nothing)
    return ""
end

function _encode_query_params(params::LexiconParams)
    T = typeof(params)
    tags = StructUtils.fieldtags(StructUtils.DefaultStyle(), T)
    parts = String[]
    for fname in fieldnames(T)
        val = getfield(params, fname)
        ftag = get(tags, fname, (;))
        wire_key = String(get(ftag, :name, fname))
        _push_query_param!(parts, wire_key, val)
    end
    return join(parts, '&')
end

function _encode_query_params(params::NamedTuple)
    parts = String[]
    for (k, v) in pairs(params)
        _push_query_param!(parts, String(k), v)
    end
    return join(parts, '&')
end

function _encode_query_params(params::AbstractDict)
    parts = String[]
    for (k, v) in pairs(params)
        _push_query_param!(parts, String(k), v)
    end
    return join(parts, '&')
end

function _decode_response(
    resp::HTTP.Response,
    out_type::Union{DataType, Nothing},
    out_encoding::Union{String, Nothing},
)
    if isnothing(out_encoding) && isnothing(out_type)
        return nothing
    end
    if out_encoding == "application/json" || (!isnothing(out_type) && isnothing(out_encoding))
        body_str = String(copy(resp.body))
        isempty(body_str) && return nothing
        return isnothing(out_type) ? JSON.parse(body_str) : JSON.parse(body_str, out_type)
    end
    # Binary / CAR / JSONL / blob response
    return Vector{UInt8}(resp.body)
end

function _normalize_extra_headers(headers)
    isnothing(headers) && return Pair{String, String}[]
    return Pair{String, String}[String(k) => String(v) for (k, v) in headers]
end

"""
    xrpc_query(agent::AtpAgent, ep::QueryEndpoint; params=nothing, headers=nothing, kwargs...)

Execute an XRPC `GET` query defined by `ep`.

Query parameters may be passed either as a typed `ep.params` struct via `params=...`,
as a `NamedTuple`/`Dict`, or directly as keyword arguments (which are validated
through `ep.params` when available).
"""
function xrpc_query(
    agent::AtpAgent,
    ep::QueryEndpoint;
    params = nothing,
    headers = nothing,
    kwargs...,
)
    resolved_params = if !isnothing(params)
        !isempty(kwargs) && throw(ArgumentError("Pass either `params` or keyword arguments, not both"))
        params
    elseif !isempty(kwargs)
        isnothing(ep.params) ? NamedTuple(kwargs) : ep.params(; kwargs...)
    else
        nothing
    end

    qs = _encode_query_params(resolved_params)
    resp = _xrpc_request(
        agent,
        "GET",
        ep.nsid;
        query_string = qs,
        extra_headers = _normalize_extra_headers(headers),
    )
    return _decode_response(resp, ep.output, ep.output_encoding)
end

"""
    xrpc_procedure(agent::AtpAgent, ep::ProcedureEndpoint; input=nothing, content_type=nothing, headers=nothing, kwargs...)

Execute an XRPC `POST` procedure defined by `ep`.

For JSON procedures, pass either a typed `ep.input` struct via `input=...` or field
keyword arguments directly. For binary procedures (e.g. `com.atproto.repo.uploadBlob`),
pass raw bytes (`AbstractVector{UInt8}`) via `input=...` and set `content_type`.
"""
function xrpc_procedure(
    agent::AtpAgent,
    ep::ProcedureEndpoint;
    input = nothing,
    content_type::Union{AbstractString, Nothing} = nothing,
    headers = nothing,
    kwargs...,
)
    resolved_input = if !isnothing(input)
        !isempty(kwargs) && throw(ArgumentError("Pass either `input` or keyword arguments, not both"))
        input
    elseif !isempty(kwargs)
        isnothing(ep.input) ? NamedTuple(kwargs) : ep.input(; kwargs...)
    else
        nothing
    end

    body, ct = if isnothing(resolved_input)
        (nothing, isnothing(content_type) ? nothing : String(content_type))
    elseif resolved_input isa AbstractVector{UInt8}
        enc = !isnothing(content_type) ? String(content_type) :
              (!isnothing(ep.input_encoding) && ep.input_encoding != "*/*" ? ep.input_encoding : "application/octet-stream")
        (Vector{UInt8}(resolved_input), enc)
    else
        enc = isnothing(content_type) ?
              (isnothing(ep.input_encoding) ? "application/json" : ep.input_encoding) :
              String(content_type)
        (JSON.json(resolved_input), enc)
    end

    resp = _xrpc_request(
        agent,
        "POST",
        ep.nsid;
        body = body,
        content_type = ct,
        extra_headers = _normalize_extra_headers(headers),
    )
    return _decode_response(resp, ep.output, ep.output_encoding)
end

function _lookup_endpoint(nsid_str::AbstractString)
    ep = get(LEXICON_ENDPOINTS, String(nsid_str), nothing)
    isnothing(ep) && throw(KeyError("Unknown Lexicon endpoint: $(nsid_str)"))
    return ep
end

"""
    xrpc(agent::AtpAgent, endpoint; kwargs...)

Dispatch an XRPC request for any Lexicon endpoint. `endpoint` may be:
- a `QueryEndpoint` or `ProcedureEndpoint`
- an `NSID` or NSID string (e.g. `"app.bsky.actor.getProfile"`)
- a generated namespace `Module` (e.g. `ATProto.API.App.Bsky.Actor.GetProfile`)
"""
xrpc(agent::AtpAgent, ep::QueryEndpoint; kwargs...) = xrpc_query(agent, ep; kwargs...)
xrpc(agent::AtpAgent, ep::ProcedureEndpoint; kwargs...) = xrpc_procedure(agent, ep; kwargs...)
xrpc(agent::AtpAgent, ep::SubscriptionEndpoint; kwargs...) =
    throw(ArgumentError("Endpoint $(ep.nsid) is a WebSocket subscription, not an HTTP query/procedure"))
xrpc(agent::AtpAgent, id::NSID; kwargs...) = xrpc(agent, _lookup_endpoint(String(id)); kwargs...)
xrpc(agent::AtpAgent, id::AbstractString; kwargs...) = xrpc(agent, _lookup_endpoint(id); kwargs...)

function xrpc(agent::AtpAgent, mod::Module; kwargs...)
    isdefined(mod, :ENDPOINT) ||
        throw(ArgumentError("Module $mod does not define an XRPC `ENDPOINT`"))
    return xrpc(agent, getfield(mod, :ENDPOINT); kwargs...)
end
