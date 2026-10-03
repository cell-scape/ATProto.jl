# Combined identity resolver. Port of `packages/identity/src/id-resolver.ts`
# plus the bidirectional identity verification from the atproto spec
# (https://atproto.com/specs/handle#identity-resolution).

"""
    IdResolver(; plc_url, timeout, did_cache, fetch, backup_nameservers, resolve_dns)

The top-level identity resolver: a [`DID.DidResolver`](@ref) plus a
[`HandleResolver`](@ref) sharing configuration.
"""
struct IdResolver{F,D}
    handle::HandleResolver{F,D}
    did::DID.DidResolver{F}
end

function IdResolver(; plc_url::AbstractString = DID.DEFAULT_PLC_URL,
                    timeout::Real = 3.0,
                    did_cache::Union{DID.DidMemoryCache,Nothing} = nothing,
                    fetch::F = DID.default_fetch,
                    backup_nameservers::Union{Vector{String},Nothing} = nothing,
                    resolve_dns::D = resolve_handle_dns) where {F,D}
    return IdResolver{F,D}(
        HandleResolver(; timeout, backup_nameservers, fetch, resolve_dns),
        DID.DidResolver(; plc_url, timeout, cache = did_cache, fetch),
    )
end

"""
    resolve_identity(r, handle; force_refresh=false) -> String

Full bidirectional identity resolution (atproto spec): resolve the handle to
a DID, resolve the DID's document, and verify the document's `alsoKnownAs`
handle matches (case-insensitively). Returns the verified DID.

Throws `HandleNotFoundError` when the handle does not resolve, and
[`IdentityMismatchError`](@ref) when the DID document declares a different
handle.
"""
function resolve_identity(r::IdResolver, handle::AbstractString;
                          force_refresh::Bool = false)::String
    did = ensure_handle(r.handle, handle)
    doc = try
        DID.ensure_resolve(r.did, did; force_refresh)
    catch err
        err isa DID.ATProtoDidError && throw(IdentityMismatchError(String(handle), did, "<unresolvable>"))
        rethrow()
    end
    doc_handle = DID.get_handle(doc)
    doc_handle === nothing &&
        throw(IdentityMismatchError(String(handle), did, "<none>"))
    lowercase(doc_handle) == lowercase(String(handle)) ||
        throw(IdentityMismatchError(String(handle), did, doc_handle))
    return did
end

"""
    ensure_identity(r, handle; kwargs...) -> String

Alias of [`resolve_identity`](@ref).
"""
ensure_identity(r::IdResolver, handle::AbstractString; kwargs...) =
    resolve_identity(r, handle; kwargs...)
