# XRPC client core. Port of `packages/xrpc/src/{xrpc-client,util}.ts`.
#
# The transport is injectable: `fetch(method, url, headers, body; timeout)`
# returning an `HTTP.Response`-like object (`status`, `body`, header lookup
# via `HTTP.headers`), defaulting to HTTP.jl — keeping tests offline.

"""
    default_fetch(method, url, headers, body; timeout) -> HTTP.Response

The standard transport (HTTP.jl request with a read timeout).
"""
default_fetch(method::AbstractString, url::AbstractString, headers, body;
              timeout::Real = 30.0) =
    HTTP.request(String(method), String(url), headers, body; readtimeout = timeout)

"Read a response header case-insensitively (works for HTTP.jl responses)."
_response_header(response, name::AbstractString) = begin
    vals = HTTP.headers(response, String(name))
    isempty(vals) ? "" : String(first(vals))
end

_response_headers(response)::Vector{Pair{String,String}} = begin
    out = Pair{String,String}[]
    for (k, v) in response.headers
        push!(out, String(k) => String(v))
    end
    out
end

"""
    encode_query_param(type, value) -> String

Encode one query-parameter value per its lexicon type
(`string`, `float`, `integer`, `boolean`, `datetime`).
"""
function encode_query_param(type::AbstractString, value)::String
    if type == "string" || type == "unknown"
        return string(value)
    elseif type == "float"
        return string(Float64(value))
    elseif type == "integer"
        return string(Int(trunc(Float64(value))))
    elseif type == "boolean"
        return value ? "true" : "false"
    elseif type == "datetime"
        return value isa Dates.DateTime ? datetime_string(value) : string(value)
    end
    throw(ArgumentError("unsupported query param type: $type"))
end

"""
    construct_method_call_url(nsid, params=Dict(); param_types=Dict()) -> String

Build the `/xrpc/<nsid>?<query>` path. Parameter types come from the lexicon
(`param_types` maps names to `"string"`, `"integer"`, `"boolean"`, `"float"`,
`"datetime"`, or `"array"` with `items` subtypes via
`param_types[name] = ("array", item_type)`); without a schema, values are
encoded as strings.
"""
function construct_method_call_url(nsid::AbstractString,
                                   params = Dict{String,Any}();
                                   param_types::Dict = Dict{String,Any}())::String
    path = string("/xrpc/", HTTP.URIs.escapeuri(String(nsid)))
    isempty(params) && return path
    query = String[]
    # Vector{Pair} params preserve order (matching the TS client's insertion
    # order); Dict params are iterated in sorted key order for determinism
    entries = params isa AbstractDict ?
              sort!(Any[string(k) => params[k] for k in keys(params)]; by = first) :
              Any[string(k) => v for (k, v) in params]
    for (key, value) in entries
        value === nothing && continue
        schema = get(param_types, String(key), nothing)
        if schema === nothing
            push!(query, string(HTTP.URIs.escapeuri(String(key)), "=",
                                HTTP.URIs.escapeuri(string(value))))
        elseif schema isa Tuple && first(schema) == "array"
            item_type = length(schema) > 1 ? schema[2] : "string"
            values = value isa AbstractVector ? value : Any[value]
            for v in values
                push!(query, string(HTTP.URIs.escapeuri(string(key)), "=",
                                    HTTP.URIs.escapeuri(encode_query_param(item_type, v))))
            end
        elseif schema isa AbstractDict && schema["type"] == "array"
            item_type = get(schema, "items", Dict{String,Any}("type" => "string"))["type"]
            values = value isa AbstractVector ? value : Any[value]
            for v in values
                push!(query, string(HTTP.URIs.escapeuri(string(key)), "=",
                                    HTTP.URIs.escapeuri(encode_query_param(item_type, v))))
            end
        else
            ptype = schema isa AbstractDict ? get(schema, "type", "string") : String(schema)
            push!(query, string(HTTP.URIs.escapeuri(string(key)), "=",
                                HTTP.URIs.escapeuri(encode_query_param(ptype, value))))
        end
    end
    isempty(query) && return path
    return string(path, "?", join(query, "&"))
end

"Parse a response body by content type (JSON -> lex values, text, or bytes)."
function parse_response_body(content_type::AbstractString,
                              body::Vector{UInt8})::Any
    try
        if occursin("application/json", content_type)
            return parse_lex(String(copy(body)))
        elseif startswith(content_type, "text/")
            return String(copy(body))
        end
        return body
    catch err
        throw(XRPCError(2, nothing, "Failed to parse response body: $(err)", Pair{String,String}[]))
    end
end

"""
    XRPCClient(; service, fetch=default_fetch, timeout=30, headers=Dict())

An XRPC client bound to a service base URL (e.g. a PDS endpoint). Extra
`headers` are attached to every call. Use [`xrpc_call`](@ref),
[`xrpc_get`](@ref), [`xrpc_proc`](@ref).
"""
struct XRPCClient{F}
    service::String
    fetch::F
    timeout::Float64
    headers::Vector{Pair{String,String}}
end

XRPCClient(; service::AbstractString, fetch::F = default_fetch,
           timeout::Real = 30.0,
           headers = Pair{String,String}[]) where {F} =
    XRPCClient{F}(rstrip(String(service), '/'), fetch, Float64(timeout),
                  Pair{String,String}[String(k) => String(v) for (k, v) in headers])

"""
    xrpc_call(client, nsid; method=:get, params=Dict(), data=nothing,
              encoding=nothing, headers=(), param_types=Dict())

Perform one XRPC call. `data` may be a lex value (serialized via
[`serialize_lex`](@ref) when `encoding` is JSON), raw bytes, or text. Returns
an [`XRPCResponse`](@ref); throws [`XRPCError`](@ref) on failure.
"""
function xrpc_call(client::XRPCClient, nsid::AbstractString;
                   method::Symbol = :get,
                   params = Dict{String,Any}(),
                   data = nothing,
                   encoding::Union{AbstractString,Nothing} = nothing,
                   headers = (),
                   param_types::Dict = Dict{String,Any}())::XRPCResponse
    url = client.service * construct_method_call_url(nsid, params; param_types)

    req_headers = Pair{String,String}[]
    for (k, v) in client.headers
        push!(req_headers, k => v)
    end
    for (k, v) in headers
        push!(req_headers, lowercase(String(k)) == "user-agent" ? String(k) => String(v) :
              String(k) => String(v))
    end
    encoding !== nothing && push!(req_headers, "Content-Type" => String(encoding))

    # body encoding (mirrors encodeMethodCallBody)
    body = nothing
    if encoding !== nothing && data !== nothing
        if data isa AbstractVector{UInt8}
            body = data
        elseif startswith(String(encoding), "text/")
            body = String(data)
        elseif occursin("application/json", String(encoding))
            body = serialize_lex(data)
        else
            body = data isa Dict ? serialize_lex(data) : String(data)
        end
    elseif encoding !== nothing
        throw(XRPCError(400, nothing, "A request body is expected but none was provided"))
    end

    response = client.fetch(String(method), url, req_headers, body;
                            timeout = client.timeout)

    content_type = _response_header(response, "Content-Type")
    res_headers = _response_headers(response)
    parsed = parse_response_body(content_type, Vector{UInt8}(copy(response.body)))

    if response.status != 200
        fields = error_body_fields(parsed)
        if fields !== nothing
            err, msg = fields
            isempty(err) && isempty(msg) && (err = response_type_string(response.status))
            throw(XRPCError(response.status, isempty(err) ? nothing : err,
                            isempty(msg) ? err : msg, res_headers))
        end
        throw(XRPCError(response.status, nothing, nothing, res_headers))
    end
    return XRPCResponse(parsed, res_headers)
end

"""
    xrpc_get(client, nsid; params=Dict(), kwargs...)

XRPC query (HTTP GET).
"""
xrpc_get(client::XRPCClient, nsid::AbstractString; params = Dict{String,Any}(),
         kwargs...) = xrpc_call(client, nsid; method = :get, params, kwargs...)

"""
    xrpc_proc(client, nsid; data=nothing, encoding=nothing, params=Dict(), kwargs...)

XRPC procedure (HTTP POST).
"""
xrpc_proc(client::XRPCClient, nsid::AbstractString;
          data = nothing, encoding::Union{AbstractString,Nothing} = nothing,
          params = Dict{String,Any}(), kwargs...) =
    xrpc_call(client, nsid; method = :post, params, data, encoding, kwargs...)
