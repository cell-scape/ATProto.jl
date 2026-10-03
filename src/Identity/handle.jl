# Handle resolution. Port of `packages/identity/src/handle/index.ts`:
# DNS TXT first, then the HTTPS well-known, then backup nameservers.

const WELL_KNOWN_PATH = "/.well-known/atproto-did"

"""
    HandleResolver(; timeout=3, backup_nameservers=nothing, fetch=default_fetch,
                     resolve_dns=resolve_handle_dns)

Resolves handles to DIDs:
1. `_atproto.<handle>` DNS TXT records (via the system resolver)
2. `https://<handle>/.well-known/atproto-did` (first line, `did=` prefixed)
3. backup nameservers, if configured

Both `fetch` (HTTP transport) and `resolve_dns` are injectable for tests.
"""
struct HandleResolver{F,D}
    timeout::Float64
    backup_nameservers::Union{Vector{String},Nothing}
    fetch::F
    resolve_dns::D
end

HandleResolver(; timeout::Real = 3.0,
              backup_nameservers::Union{Vector{String},Nothing} = nothing,
              fetch::F = DID.default_fetch,
              resolve_dns::D = resolve_handle_dns) where {F,D} =
    HandleResolver{F,D}(Float64(timeout), backup_nameservers, fetch, resolve_dns)

"""
    resolve_handle_http(r, handle) -> Union{String, Nothing}

Fetch `https://<handle>/.well-known/atproto-did` and return the first line
when it is a `did:...` value. Redirects are followed.
"""
function resolve_handle_http(r::HandleResolver, handle::AbstractString)::Union{String,Nothing}
    url = "https://" * String(handle) * WELL_KNOWN_PATH
    res = try
        r.fetch(url; headers = ["Accept" => "text/plain"], timeout = r.timeout)
    catch
        return nothing
    end
    res.status == 200 || return nothing
    body = String(copy(res.body))
    did = first(split(body, '\n')) |> strip
    did_str = String(did)
    startswith(did_str, "did:") || return nothing
    return did_str
end

"""
    resolve_handle(r, handle) -> Union{String, Nothing}

Resolve a handle to a DID (DNS TXT, then well-known HTTP, then backup
nameservers). `nothing` when the handle has no valid atproto record.
"""
function resolve_handle(r::HandleResolver, handle::AbstractString)::Union{String,Nothing}
    did = try
        r.resolve_dns(handle)
    catch
        nothing
    end
    did !== nothing && return did

    did = resolve_handle_http(r, handle)
    did !== nothing && return did

    if r.backup_nameservers !== nothing && !isempty(r.backup_nameservers)
        return resolve_handle_dns(handle; nameservers = r.backup_nameservers,
                                  timeout = r.timeout)
    end
    return nothing
end

"""
    ensure_handle(r, handle) -> String

Like [`resolve_handle`](@ref) but throws `HandleNotFoundError`.
"""
function ensure_handle(r::HandleResolver, handle::AbstractString)::String
    did = resolve_handle(r, handle)
    did === nothing && throw(HandleNotFoundError(String(handle)))
    return did
end
