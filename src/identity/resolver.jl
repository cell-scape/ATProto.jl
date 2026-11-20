#= identity/resolver.jl =#

"""
    DEFAULT_PLC_URL

Default PLC directory base URL (`"https://plc.directory"`).
"""
const DEFAULT_PLC_URL = "https://plc.directory"

"""
    DEFAULT_DOH_URL

Default DNS-over-HTTPS JSON endpoint (`"https://dns.google/resolve"`) used for
`_atproto.<handle>` TXT lookups with zero external DNS binaries.
"""
const DEFAULT_DOH_URL = "https://dns.google/resolve"

function _default_id_http(
    url::String,
    headers::Vector{Pair{String, String}};
    timeout::Real = 10.0,
)
    t = Float64(timeout)
    return HTTP.request(
        "GET",
        url,
        headers;
        status_exception = false,
        read_idle_timeout = t,
        connect_timeout = t,
    )
end

struct _CacheEntry{T}
    value::T
    expires_at::Float64
end

"""
    ResolvedIdentity

Result of resolving an AT Protocol identifier (`DID` or `Handle`), including
bidirectional handle verification status, PDS endpoint, signing key, and full
[`DIDDocument`](@ref).
"""
struct ResolvedIdentity
    did::DID
    handle::Union{Handle, Nothing}
    pds::Union{String, Nothing}
    signing_key::Union{DIDVerificationMethod, Nothing}
    did_doc::DIDDocument
    handle_verified::Bool
end

function Base.show(io::IO, id::ResolvedIdentity)
    print(io, "ResolvedIdentity(did=", repr(String(id.did)),
          ", handle=", repr(id.handle),
          ", verified=", id.handle_verified,
          ", pds=", repr(id.pds), ")")
end

"""
    IdentityResolver(; plc_url=DEFAULT_PLC_URL, doh_url=DEFAULT_DOH_URL, cache_ttl=300.0, timeout=10.0, http_transport=..., dns_resolver=nothing)

Thread-safe AT Protocol identity resolver supporting:
- `did:plc` resolution via `plc.directory`
- `did:web` resolution via `/.well-known/did.json`
- Handle resolution via DNS TXT (`_atproto.<handle>`, using DNS-over-HTTPS by default)
  and HTTPS (`https://<handle>/.well-known/atproto-did`)
- Bidirectional handle ↔ DID verification ([`verify_handle`](@ref), [`resolve_identity`](@ref))
- In-memory TTL caching (`cache_ttl` seconds; set `cache_ttl = 0.0` to disable)
"""
mutable struct IdentityResolver
    const plc_url::String
    const doh_url::String
    const cache_ttl::Float64
    const timeout::Float64
    const http_transport::Any
    const dns_resolver::Any
    const lock::ReentrantLock
    const did_cache::Dict{DID, _CacheEntry{DIDDocument}}
    const handle_cache::Dict{Handle, _CacheEntry{Union{DID, Nothing}}}
end

function IdentityResolver(;
    plc_url::AbstractString = DEFAULT_PLC_URL,
    doh_url::AbstractString = DEFAULT_DOH_URL,
    cache_ttl::Real = 300.0,
    timeout::Real = 10.0,
    http_transport = _default_id_http,
    dns_resolver = nothing,
)
    return IdentityResolver(
        String(rstrip(plc_url, '/')),
        String(doh_url),
        Float64(cache_ttl),
        Float64(timeout),
        http_transport,
        dns_resolver,
        ReentrantLock(),
        Dict{DID, _CacheEntry{DIDDocument}}(),
        Dict{Handle, _CacheEntry{Union{DID, Nothing}}}(),
    )
end

const _DEFAULT_RESOLVER = IdentityResolver()

"""
    clear_cache!(resolver::IdentityResolver) -> Nothing

Clear all cached DID documents and handle resolutions from `resolver`.
"""
function clear_cache!(resolver::IdentityResolver)
    Base.@lock resolver.lock begin
        empty!(resolver.did_cache)
        empty!(resolver.handle_cache)
    end
    return nothing
end

# -----------------------------------------------------------------------------
# DID Resolution (did:plc and did:web)
# -----------------------------------------------------------------------------

"""
    did_web_url(did::Union{DID, AbstractString}) -> String

Compute the `/.well-known/did.json` URL for an AT Protocol `did:web` identifier.
Rejects path-based `did:web` identifiers (which AT Protocol disallows).
"""
function did_web_url(d::DID)
    did_method(d) == "web" ||
        throw(IdentityError(String(d), "Expected 'did:web' method, got 'did:$(did_method(d))'"))
    ident = String(did_identifier(d))
    occursin(':', ident) &&
        throw(IdentityError(String(d), "AT Protocol did:web identifiers cannot contain path segments"))
    # Percent-decode encoded port separator (%3A / %3a)
    host = replace(ident, r"%3[aA]" => ":")
    # Reject any remaining percent escapes or slashes
    (occursin('%', host) || occursin('/', host)) &&
        throw(IdentityError(String(d), "Unsupported characters in did:web host"))
    host_only = first(split(host, ':'))
    scheme = (host_only == "localhost" || host_only == "127.0.0.1") ? "http" : "https"
    return string(scheme, "://", host, "/.well-known/did.json")
end

did_web_url(s::AbstractString) = did_web_url(DID(s))

_id_body_string(body::AbstractString) = String(body)
_id_body_string(body::AbstractVector{UInt8}) = String(copy(body))

function _fetch_did_document(resolver::IdentityResolver, d::DID)
    m = did_method(d)
    url = if m == "plc"
        string(resolver.plc_url, "/", d)
    elseif m == "web"
        did_web_url(d)
    else
        throw(IdentityError(String(d), "Unsupported DID method 'did:$m' (AT Protocol supports did:plc and did:web)"))
    end

    resp = resolver.http_transport(url, ["Accept" => "application/did+ld+json, application/json"]; timeout = resolver.timeout)
    if !(200 <= resp.status < 300)
        throw(IdentityError(String(d), "HTTP $(resp.status) resolving DID document from $url"))
    end
    doc = parse_did_document(_id_body_string(resp.body))
    if doc.id != d
        throw(IdentityError(String(d), "DID document id mismatch: expected $(d), got $(doc.id)"))
    end
    return doc
end

"""
    resolve_did(resolver::IdentityResolver, did::Union{DID, AbstractString}; force_refresh=false) -> DIDDocument
    resolve_did(did::Union{DID, AbstractString}; force_refresh=false) -> DIDDocument

Resolve a `did:plc` or `did:web` identifier to its validated [`DIDDocument`](@ref).
"""
function resolve_did(
    resolver::IdentityResolver,
    did::Union{DID, AbstractString};
    force_refresh::Bool = false,
)
    d = convert(DID, did)
    now_t = time()
    if !force_refresh && resolver.cache_ttl > 0
        cached = Base.@lock resolver.lock begin
            entry = get(resolver.did_cache, d, nothing)
            (!isnothing(entry) && entry.expires_at > now_t) ? entry.value : nothing
        end
        isnothing(cached) || return cached
    end

    doc = _fetch_did_document(resolver, d)
    if resolver.cache_ttl > 0
        Base.@lock resolver.lock begin
            resolver.did_cache[d] = _CacheEntry(doc, time() + resolver.cache_ttl)
        end
    end
    return doc
end

resolve_did(did::Union{DID, AbstractString}; force_refresh::Bool = false) =
    resolve_did(_DEFAULT_RESOLVER, did; force_refresh)

# -----------------------------------------------------------------------------
# Handle Resolution (DNS TXT `_atproto.<handle>` + HTTPS `/.well-known/atproto-did`)
# -----------------------------------------------------------------------------

function _parse_txt_records_for_did(records::AbstractVector{<:AbstractString})
    found = Set{DID}()
    for raw in records
        # Strip surrounding RFC 1035 quotes if present
        s = strip(String(raw))
        if ncodeunits(s) >= 2 && first(s) == '"' && last(s) == '"'
            s = s[2:prevind(s, lastindex(s))]
        end
        startswith(s, "did=") || continue
        cand = SubString(s, 5)
        d = tryparse(DID, cand)
        isnothing(d) || push!(found, d)
    end
    # Ambiguous if multiple distinct DIDs are advertised in DNS TXT
    length(found) == 1 && return first(found)
    return nothing
end

function _query_doh_txt(resolver::IdentityResolver, domain::String)
    sep = occursin('?', resolver.doh_url) ? '&' : '?'
    url = string(resolver.doh_url, sep, "name=", HTTP.URIs.escapeuri(domain), "&type=TXT")
    resp = resolver.http_transport(url, ["Accept" => "application/dns-json"]; timeout = resolver.timeout)
    (200 <= resp.status < 300) || return String[]

    body = _id_body_string(resp.body)
    parsed = try
        JSON.parse(body, Dict{String, Any})
    catch
        return String[]
    end
    get(parsed, "Status", -1) == 0 || return String[]
    answers = get(parsed, "Answer", nothing)
    answers isa AbstractVector || return String[]

    txts = String[]
    for ans in answers
        ans isa AbstractDict || continue
        # DNS record type 16 == TXT
        get(ans, "type", 0) == 16 || continue
        data = get(ans, "data", nothing)
        data isa AbstractString && push!(txts, String(data))
    end
    return txts
end

function _resolve_handle_dns(resolver::IdentityResolver, h::Handle)
    domain = string("_atproto.", h)
    records = if !isnothing(resolver.dns_resolver)
        resolver.dns_resolver(domain)
    else
        _query_doh_txt(resolver, domain)
    end
    return _parse_txt_records_for_did(records)
end

function _resolve_handle_https(resolver::IdentityResolver, h::Handle)
    url = string("https://", h, "/.well-known/atproto-did")
    resp = try
        resolver.http_transport(url, ["Accept" => "text/plain"]; timeout = resolver.timeout)
    catch
        return nothing
    end
    (200 <= resp.status < 300) || return nothing
    body = strip(_id_body_string(resp.body))
    isempty(body) && return nothing
    # ATProto well-known response must be a single DID (first line, no extra junk)
    first_line = strip(first(split(body, '\n')))
    return tryparse(DID, first_line)
end

"""
    resolve_handle(resolver::IdentityResolver, handle::Union{Handle, AbstractString}; method=:auto, force_refresh=false) -> Union{DID, Nothing}
    resolve_handle(handle::Union{Handle, AbstractString}; method=:auto, force_refresh=false) -> Union{DID, Nothing}

Resolve an AT Protocol handle to its [`DID`](@ref) (or `nothing` if unresolvable).

`method` controls the lookup strategy:
- `:auto` (default): tries DNS TXT (`_atproto.<handle>`) first, falling back to
  HTTPS (`https://<handle>/.well-known/atproto-did`).
- `:dns`: DNS TXT lookup only.
- `:https`: HTTPS well-known lookup only.
"""
function resolve_handle(
    resolver::IdentityResolver,
    handle::Union{Handle, AbstractString};
    method::Symbol = :auto,
    force_refresh::Bool = false,
)
    method in (:auto, :dns, :https) ||
        throw(ArgumentError("Invalid handle resolution method :$method (expected :auto, :dns, or :https)"))

    h = convert(Handle, handle)
    now_t = time()
    if method == :auto && !force_refresh && resolver.cache_ttl > 0
        cached = Base.@lock resolver.lock begin
            entry = get(resolver.handle_cache, h, nothing)
            (!isnothing(entry) && entry.expires_at > now_t) ? (true, entry.value) : (false, nothing)
        end
        cached[1] && return cached[2]
    end

    did = if method == :dns
        _resolve_handle_dns(resolver, h)
    elseif method == :https
        _resolve_handle_https(resolver, h)
    else
        d = try
            _resolve_handle_dns(resolver, h)
        catch
            nothing
        end
        isnothing(d) ? _resolve_handle_https(resolver, h) : d
    end

    if method == :auto && resolver.cache_ttl > 0
        Base.@lock resolver.lock begin
            resolver.handle_cache[h] = _CacheEntry{Union{DID, Nothing}}(did, time() + resolver.cache_ttl)
        end
    end
    return did
end

resolve_handle(handle::Union{Handle, AbstractString}; method::Symbol = :auto, force_refresh::Bool = false) =
    resolve_handle(_DEFAULT_RESOLVER, handle; method, force_refresh)

# -----------------------------------------------------------------------------
# Bidirectional Handle Verification & Unified Identity Resolution
# -----------------------------------------------------------------------------

"""
    verify_handle(resolver::IdentityResolver, handle, did) -> Bool
    verify_handle(handle, did) -> Bool

Perform AT Protocol bidirectional handle verification:
1. `resolve_handle(resolver, handle) == did`
2. `atproto_handle(resolve_did(resolver, did)) == handle`
"""
function verify_handle(
    resolver::IdentityResolver,
    handle::Union{Handle, AbstractString},
    did::Union{DID, AbstractString},
)
    h = convert(Handle, handle)
    d = convert(DID, did)
    resolved_did = resolve_handle(resolver, h)
    resolved_did == d || return false
    doc = try
        resolve_did(resolver, d)
    catch
        return false
    end
    return atproto_handle(doc) == h
end

verify_handle(handle::Union{Handle, AbstractString}, did::Union{DID, AbstractString}) =
    verify_handle(_DEFAULT_RESOLVER, handle, did)

"""
    resolve_identity(resolver::IdentityResolver, id::Union{DID, Handle, AbstractString}; force_refresh=false) -> ResolvedIdentity
    resolve_identity(id::Union{DID, Handle, AbstractString}; force_refresh=false) -> ResolvedIdentity

Resolve a `DID` or `Handle` to a [`ResolvedIdentity`](@ref) with bidirectional
handle verification, PDS endpoint, signing key, and full [`DIDDocument`](@ref).
"""
function resolve_identity(
    resolver::IdentityResolver,
    d::DID;
    force_refresh::Bool = false,
)
    doc = resolve_did(resolver, d; force_refresh)
    claimed = atproto_handle(doc)
    verified = if isnothing(claimed)
        false
    else
        resolve_handle(resolver, claimed; force_refresh) == d
    end
    return ResolvedIdentity(
        d,
        claimed,
        pds_endpoint(doc),
        signing_key(doc),
        doc,
        verified,
    )
end

function resolve_identity(
    resolver::IdentityResolver,
    h::Handle;
    force_refresh::Bool = false,
)
    d = resolve_handle(resolver, h; force_refresh)
    isnothing(d) && throw(IdentityError(String(h), "Could not resolve handle to a DID"))
    doc = resolve_did(resolver, d; force_refresh)
    claimed = atproto_handle(doc)
    verified = (claimed == h)
    return ResolvedIdentity(
        d,
        verified ? h : claimed,
        pds_endpoint(doc),
        signing_key(doc),
        doc,
        verified,
    )
end

function resolve_identity(
    resolver::IdentityResolver,
    s::AbstractString;
    force_refresh::Bool = false,
)
    if startswith(s, "did:")
        return resolve_identity(resolver, DID(s); force_refresh)
    end
    return resolve_identity(resolver, Handle(s); force_refresh)
end

resolve_identity(id::Union{DID, Handle, AbstractString}; force_refresh::Bool = false) =
    resolve_identity(_DEFAULT_RESOLVER, id; force_refresh)
