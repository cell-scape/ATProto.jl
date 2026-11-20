#= client/pagination.jl =#

function _resolve_query_endpoint(ep::QueryEndpoint)
    return ep
end
function _resolve_query_endpoint(id::NSID)
    ep = _lookup_endpoint(String(id))
    ep isa QueryEndpoint || throw(ArgumentError("Endpoint $id is not a QueryEndpoint"))
    return ep
end
function _resolve_query_endpoint(id::AbstractString)
    ep = _lookup_endpoint(id)
    ep isa QueryEndpoint || throw(ArgumentError("Endpoint $id is not a QueryEndpoint"))
    return ep
end
function _resolve_query_endpoint(mod::Module)
    isdefined(mod, :ENDPOINT) || throw(ArgumentError("Module $mod does not define `ENDPOINT`"))
    ep = getfield(mod, :ENDPOINT)
    ep isa QueryEndpoint || throw(ArgumentError("Endpoint in $mod is not a QueryEndpoint"))
    return ep
end

function _infer_items_field(ep::QueryEndpoint)
    isnothing(ep.output) && throw(ArgumentError("Endpoint $(ep.nsid) has no typed output schema"))
    vfields = Symbol[]
    for f in fieldnames(ep.output)
        ft = fieldtype(ep.output, f)
        is_vec = ft <: AbstractVector || (ft isa Union && any(t -> t <: AbstractVector, Base.uniontypes(ft)))
        is_vec && push!(vfields, f)
    end
    length(vfields) == 1 && return first(vfields)
    throw(ArgumentError(
        "Cannot unambiguously infer items field for $(ep.nsid) (vector fields: $(vfields)); pass `field::Symbol` explicitly",
    ))
end

function _items_eltype(output_type::DataType, field::Symbol)
    ft = fieldtype(output_type, field)
    if ft <: AbstractVector
        return eltype(ft)
    elseif ft isa Union
        for t in Base.uniontypes(ft)
            t <: AbstractVector && return eltype(t)
        end
    end
    return Any
end

"""
    XRPCPages{Out}

Lazy Julia iterator over pages of a cursor-paginated XRPC `QueryEndpoint`.
Construct via [`eachpage`](@ref).
"""
struct XRPCPages{Out}
    agent::AtpAgent
    endpoint::QueryEndpoint
    base_kwargs::NamedTuple
    initial_cursor::Union{String, Nothing}
    max_pages::Union{Int, Nothing}
    headers::Union{Vector{Pair{String, String}}, Nothing}
end

Base.IteratorSize(::Type{<:XRPCPages}) = Base.SizeUnknown()
Base.eltype(::Type{XRPCPages{Out}}) where {Out} = Out

function _fetch_page(p::XRPCPages, cursor::Union{String, Nothing})
    kw = isnothing(cursor) ? p.base_kwargs : merge(p.base_kwargs, (; cursor = cursor))
    return xrpc_query(p.agent, p.endpoint; headers = p.headers, kw...)
end

function _next_cursor(page, prev_cursor::Union{String, Nothing})
    hasproperty(page, :cursor) || return nothing
    c = getproperty(page, :cursor)
    (isnothing(c) || isempty(c)) && return nothing
    # Guard against servers repeating the same cursor indefinitely
    c == prev_cursor && return nothing
    return String(c)
end

function Base.iterate(p::XRPCPages)
    if !isnothing(p.max_pages) && p.max_pages <= 0
        return nothing
    end
    page = _fetch_page(p, p.initial_cursor)
    next_c = _next_cursor(page, p.initial_cursor)
    return (page, (next_c, 1))
end

function Base.iterate(p::XRPCPages, state::Tuple{Union{String, Nothing}, Int})
    next_c, page_count = state
    isnothing(next_c) && return nothing
    if !isnothing(p.max_pages) && page_count >= p.max_pages
        return nothing
    end
    page = _fetch_page(p, next_c)
    following_c = _next_cursor(page, next_c)
    return (page, (following_c, page_count + 1))
end

"""
    eachpage(agent::AtpAgent, endpoint; cursor=nothing, max_pages=nothing, headers=nothing, kwargs...) -> XRPCPages

Return a lazy iterator yielding each response page from a cursor-paginated XRPC
query endpoint. Automatically forwards `cursor` between pages and stops when the
server returns no cursor, repeats the cursor, or `max_pages` is reached.

# Example
```julia
for page in eachpage(agent, "app.bsky.feed.getAuthorFeed"; actor="bsky.app", limit=50, max_pages=3)
    println("Fetched ", length(page.feed), " items")
end
```
"""
function eachpage(
    agent::AtpAgent,
    endpoint;
    cursor::Union{AbstractString, Nothing} = nothing,
    max_pages::Union{Integer, Nothing} = nothing,
    headers = nothing,
    kwargs...,
)
    ep = _resolve_query_endpoint(endpoint)
    (!isnothing(ep.params) && (:cursor in fieldnames(ep.params))) ||
        throw(ArgumentError("Endpoint $(ep.nsid) does not accept a `cursor` parameter"))
    (!isnothing(ep.output) && (:cursor in fieldnames(ep.output))) ||
        throw(ArgumentError("Endpoint $(ep.nsid) does not return a `cursor` field"))

    out_t = ep.output
    init_c = isnothing(cursor) ? nothing : String(cursor)
    mp = isnothing(max_pages) ? nothing : Int(max_pages)
    hdrs = isnothing(headers) ? nothing : _normalize_extra_headers(headers)
    return XRPCPages{out_t}(agent, ep, NamedTuple(kwargs), init_c, mp, hdrs)
end

"""
    XRPCItems{El, Out}

Lazy Julia iterator yielding individual items across pages of a cursor-paginated
XRPC query endpoint. Construct via [`eachitem`](@ref).
"""
struct XRPCItems{El, Out}
    pages::XRPCPages{Out}
    field::Symbol
end

Base.IteratorSize(::Type{<:XRPCItems}) = Base.SizeUnknown()
Base.eltype(::Type{XRPCItems{El, Out}}) where {El, Out} = El

function _advance_items(it::XRPCItems, page_iter_res)
    while !isnothing(page_iter_res)
        page, page_state = page_iter_res
        vec = getproperty(page, it.field)
        if !isnothing(vec) && !isempty(vec)
            return (first(vec), (vec, 2, page_state))
        end
        page_iter_res = iterate(it.pages, page_state)
    end
    return nothing
end

Base.iterate(it::XRPCItems) = _advance_items(it, iterate(it.pages))

function Base.iterate(it::XRPCItems, state)
    vec, idx, page_state = state
    if idx <= length(vec)
        return (vec[idx], (vec, idx + 1, page_state))
    end
    return _advance_items(it, iterate(it.pages, page_state))
end

"""
    eachitem(agent::AtpAgent, endpoint, [field::Symbol]; cursor=nothing, max_pages=nothing, headers=nothing, kwargs...) -> XRPCItems

Return a lazy, typed iterator over individual elements across pages of a
cursor-paginated XRPC query endpoint.

When `field` is omitted, the single vector field on the endpoint's output struct
(e.g. `:feed`, `:followers`, `:records`, `:posts`) is inferred automatically.
Composes directly with `Base.Iterators` (e.g. `Iterators.take`, `Iterators.filter`).

# Example
```julia
posts = collect(Iterators.take(eachitem(agent, "app.bsky.feed.getAuthorFeed"; actor="bsky.app"), 25))
```
"""
function eachitem(
    agent::AtpAgent,
    endpoint,
    field::Symbol;
    cursor::Union{AbstractString, Nothing} = nothing,
    max_pages::Union{Integer, Nothing} = nothing,
    headers = nothing,
    kwargs...,
)
    pages = eachpage(agent, endpoint; cursor, max_pages, headers, kwargs...)
    ep = pages.endpoint
    out_t = ep.output
    isnothing(out_t) && throw(ArgumentError("Endpoint $(ep.nsid) has no typed output schema"))
    field in fieldnames(out_t) ||
        throw(ArgumentError("Output type $(out_t) has no field :$field"))
    el_t = _items_eltype(out_t, field)
    return XRPCItems{el_t, out_t}(pages, field)
end

function eachitem(
    agent::AtpAgent,
    endpoint;
    cursor::Union{AbstractString, Nothing} = nothing,
    max_pages::Union{Integer, Nothing} = nothing,
    headers = nothing,
    kwargs...,
)
    ep = _resolve_query_endpoint(endpoint)
    field = _infer_items_field(ep)
    return eachitem(agent, ep, field; cursor, max_pages, headers, kwargs...)
end
