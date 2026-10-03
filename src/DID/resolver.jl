# DID resolvers with injectable transport. Port of
# `packages/identity/src/did/{plc,web,did}-resolver.ts`.
#
# The transport is any function `fetch(url; headers, timeout)` returning an
# `HTTP.Response`-like object (`status::Int`, `body`), defaulting to HTTP.jl.
# This keeps resolvers fully testable offline.

"""
    default_fetch(url; headers, timeout)

The standard HTTP transport (HTTP.jl GET with a read timeout).
"""
default_fetch(url::AbstractString; headers = (), timeout::Real = 3.0) =
    HTTP.get(url; headers = headers, readtimeout = timeout)

const DEFAULT_PLC_URL = "https://plc.directory"

"""
    PlcResolver(; plc_url=DEFAULT_PLC_URL, timeout=3, fetch=default_fetch)

Resolver for `did:plc` via a plc.directory-compatible server.
"""
struct PlcResolver{F}
    plc_url::String
    timeout::Float64
    fetch::F
end

PlcResolver(; plc_url::AbstractString = DEFAULT_PLC_URL, timeout::Real = 3.0,
            fetch::F = default_fetch) where {F} =
    PlcResolver{F}(String(plc_url), Float64(timeout), fetch)

function resolve_no_check(resolver::PlcResolver, did::AbstractString)
    url = resolver.plc_url * "/" * HTTP.URIs.escapeuri(did)
    res = resolver.fetch(url;
        headers = ["Accept" => "application/did+ld+json,application/json"],
        timeout = resolver.timeout)
    # positively not found (vs. network error)
    res.status == 404 && return nothing
    res.status == 200 || throw(ErrorException("plc directory error: HTTP $(res.status)"))
    return JSON.parse(String(copy(res.body)))
end

const DOC_PATH = "/.well-known/did.json"

"""
    WebResolver(; timeout=3, fetch=default_fetch)

Resolver for `did:web` via `https://<host>/.well-known/did.json` (or `http`
for localhost). Path components (colon-separated) are rejected, as atproto
does not support them.
"""
struct WebResolver{F}
    timeout::Float64
    fetch::F
end

WebResolver(; timeout::Real = 3.0, fetch::F = default_fetch) where {F} =
    WebResolver{F}(Float64(timeout), fetch)

function resolve_no_check(resolver::WebResolver, did::AbstractString)
    startswith(did, DID_WEB_PREFIX) || throw(PoorlyFormattedDidError(String(did)))
    msid = did[length(DID_WEB_PREFIX)+1:end]
    parts = split(msid, ':')
    length(parts) == 1 || throw(UnsupportedDidWebPathError(String(did)))
    host = parts[1]
    proto = startswith(host, "localhost") ? "http" : "https"
    url = "$proto://$host$DOC_PATH"
    res = resolver.fetch(url;
        headers = ["Accept" => "application/did+ld+json,application/json"],
        timeout = resolver.timeout)
    res.status == 200 || return nothing  # any non-ok is "not found" for did:web
    return JSON.parse(String(copy(res.body)))
end

"""
    DidResolver(; plc_url, timeout, cache, fetch)

Dispatching DID resolver: `did:plc` → plc.directory, `did:web` → well-known.
Supports the same stale-while-revalidate caching as the TS reference.
"""
struct DidResolver{F}
    plc::PlcResolver{F}
    web::WebResolver{F}
    cache::Union{DidMemoryCache,Nothing}
end

DidResolver(; plc_url::AbstractString = DEFAULT_PLC_URL, timeout::Real = 3.0,
            cache::Union{DidMemoryCache,Nothing} = nothing,
            fetch::F = default_fetch) where {F} =
    DidResolver{F}(PlcResolver(; plc_url, timeout, fetch),
                   WebResolver(; timeout, fetch), cache)

function _method_resolver(r::DidResolver, did::AbstractString)
    if startswith(did, "did:")
        parts = split(did, ':')
        length(parts) >= 3 || throw(PoorlyFormattedDidError(String(did)))
        method = parts[2]
        method == "plc" && return r.plc
        method == "web" && return r.web
        throw(UnsupportedDidMethodError(String(did)))
    end
    throw(PoorlyFormattedDidError(String(did)))
end

resolve_no_check(r::DidResolver, did::AbstractString) =
    resolve_no_check(_method_resolver(r, did), did)

function _resolve_no_cache(r::DidResolver, did::AbstractString)::Union{DidDocument,Nothing}
    got = resolve_no_check(r, did)
    got === nothing && return nothing
    return parse_did_document(did, got)
end

"""
    resolve_document(r, did; force_refresh=false) -> Union{DidDocument, Nothing}

Resolve a DID to its document, consulting the cache first (stale entries are
served while a refresh happens in the background). `nothing` when the DID
positively does not exist.
"""
function resolve_document(r::DidResolver, did::AbstractString;
                          force_refresh::Bool = false)::Union{DidDocument,Nothing}
    if r.cache !== nothing && !force_refresh
        from_cache = check_cache(r.cache, did)
        if from_cache !== nothing && !from_cache.expired
            return from_cache.doc  # stale entries are served as-is
        end
    end
    got = _resolve_no_cache(r, did)
    if got === nothing
        r.cache === nothing || clear_entry!(r.cache, did)
        return nothing
    end
    r.cache === nothing || cache_did!(r.cache, did, got)
    return got
end

"""
    ensure_resolve(r, did; force_refresh=false) -> DidDocument

Like [`resolve_document`](@ref) but throws `DidNotFoundError` instead of
returning `nothing`.
"""
function ensure_resolve(r::DidResolver, did::AbstractString;
                        force_refresh::Bool = false)::DidDocument
    doc = resolve_document(r, did; force_refresh)
    doc === nothing && throw(DidNotFoundError(String(did)))
    return doc
end

"Convenience alias matching the TS API."
resolve(r::DidResolver, did::AbstractString; kwargs...) = resolve_document(r, did; kwargs...)

"""
    resolve_atproto_data(r, did) -> AtprotoData

Resolve a DID and extract its atproto data (signing key, handle, PDS).
"""
resolve_atproto_data(r::DidResolver, did::AbstractString; kwargs...) =
    ensure_atproto_data(ensure_resolve(r, did; kwargs...))

"""
    resolve_atproto_key(r, did) -> String

Resolve the DID's atproto signing key (`did:key:z...`); `did:key:` inputs
are returned as-is.
"""
function resolve_atproto_key(r::DidResolver, did::AbstractString; kwargs...)::String
    startswith(did, "did:key:") && return String(did)
    key = get_signing_key(ensure_resolve(r, did; kwargs...))
    key === nothing && throw(ArgumentError("Could not parse signingKey from doc"))
    return key
end

"""
    verify_signature(r, did, data, sig; kwargs...) -> Bool

Resolve the DID's signing key and verify a compact signature over `data`.
"""
function verify_signature(r::DidResolver, did::AbstractString,
                          data::AbstractVector{UInt8}, sig::AbstractVector{UInt8};
                          kwargs...)::Bool
    key = resolve_atproto_key(r, did; kwargs...)
    return verify_did_sig(key, data, sig)
end
