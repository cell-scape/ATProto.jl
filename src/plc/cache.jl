# DID resolution caches. Port of `packages/identity/src/did/memory-cache.ts`
# (stale-while-revalidate semantics).

"""
Result of a cache lookup: the cached document, when it was stored, and
whether it is now stale (older than `stale_ttl`) or expired (older than
`max_ttl`).
"""
struct CacheResult
    doc::DidDocument
    updated_at::Float64  # seconds since epoch
    stale::Bool
    expired::Bool
end

"""
    DidMemoryCache(; stale_ttl=3600, max_ttl=86400, now=time)

An in-memory DID document cache with stale-while-revalidate semantics:
entries older than `stale_ttl` are served but flagged for refresh; entries
older than `max_ttl` are treated as absent. `now` is injectable for tests.
"""
mutable struct DidMemoryCache
    stale_ttl::Float64
    max_ttl::Float64
    now::Function
    entries::Dict{String,CacheResult}

    function DidMemoryCache(; stale_ttl::Real = 3600.0, max_ttl::Real = 86400.0,
                            now::Function = time)
        return new(Float64(stale_ttl), Float64(max_ttl), now,
                   Dict{String,CacheResult}())
    end
end

"Store a freshly resolved document."
function cache_did!(cache::DidMemoryCache, did::AbstractString, doc::DidDocument)
    cache.entries[String(did)] = CacheResult(doc, cache.now(), false, false)
    return nothing
end

"Look up a cached document; `nothing` when absent or expired."
function check_cache(cache::DidMemoryCache, did::AbstractString)::Union{CacheResult,Nothing}
    entry = get(cache.entries, String(did), nothing)
    entry === nothing && return nothing
    age = cache.now() - entry.updated_at
    stale = age > cache.stale_ttl
    expired = age > cache.max_ttl
    return CacheResult(entry.doc, entry.updated_at, stale, expired)
end

"Drop a cached entry (e.g. after a 404)."
clear_entry!(cache::DidMemoryCache, did::AbstractString) =
    (delete!(cache.entries, String(did)); nothing)

"Drop all cached entries."
clear!(cache::DidMemoryCache) = (empty!(cache.entries); nothing)
