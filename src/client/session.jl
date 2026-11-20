#= client/session.jl =#

"""
    Session

Authenticated AT Protocol session snapshot holding account identity and JWTs.

Tokens are redacted in `Base.show` to prevent accidental leakage into logs or REPL output.
"""
struct Session
    did::DID
    handle::Handle
    access_jwt::String
    refresh_jwt::String
    email::Union{String, Nothing}
    active::Union{Bool, Nothing}
    status::Union{String, Nothing}
    did_doc::Union{LexiconObject, Nothing}
end

function Session(;
    did::Union{DID, AbstractString},
    handle::Union{Handle, AbstractString},
    access_jwt::AbstractString,
    refresh_jwt::AbstractString,
    email::Union{AbstractString, Nothing} = nothing,
    active::Union{Bool, Nothing} = nothing,
    status::Union{AbstractString, Nothing} = nothing,
    did_doc::Union{LexiconObject, Nothing} = nothing,
)
    return Session(
        convert(DID, did),
        convert(Handle, handle),
        String(access_jwt),
        String(refresh_jwt),
        isnothing(email) ? nothing : String(email),
        active,
        isnothing(status) ? nothing : String(status),
        did_doc,
    )
end

function Base.show(io::IO, s::Session)
    print(io, "Session(handle=", repr(String(s.handle)),
          ", did=", repr(String(s.did)),
          ", active=", s.active,
          ", tokens=<redacted>)")
end

"""
    RateLimitInfo

Rate-limit metadata parsed from AT Protocol `RateLimit-*` HTTP response headers.
"""
struct RateLimitInfo
    limit::Union{Int, Nothing}
    remaining::Union{Int, Nothing}
    reset::Union{Int, Nothing}
    policy::Union{String, Nothing}
end

function _parse_rate_limit(resp::HTTP.Response)
    lim_s = HTTP.header(resp, "ratelimit-limit", "")
    rem_s = HTTP.header(resp, "ratelimit-remaining", "")
    rst_s = HTTP.header(resp, "ratelimit-reset", "")
    pol_s = HTTP.header(resp, "ratelimit-policy", "")

    if isempty(lim_s) && isempty(rem_s) && isempty(rst_s) && isempty(pol_s)
        return nothing
    end

    lim = isempty(lim_s) ? nothing : tryparse(Int, strip(lim_s))
    rem = isempty(rem_s) ? nothing : tryparse(Int, strip(rem_s))
    rst = isempty(rst_s) ? nothing : tryparse(Int, strip(rst_s))
    pol = isempty(pol_s) ? nothing : String(strip(pol_s))
    return RateLimitInfo(lim, rem, rst, pol)
end

"""
Extract the personal PDS `serviceEndpoint` URL from a DID document (if present).
"""
function _extract_pds_endpoint(did_doc::Union{LexiconObject, Nothing})
    did_doc isa UnknownObject || return nothing
    services = get(did_doc.data, "service", nothing)
    services isa AbstractVector || return nothing
    for svc in services
        svc isa AbstractDict || continue
        id = get(svc, "id", nothing)
        stype = get(svc, "type", nothing)
        endpoint = get(svc, "serviceEndpoint", nothing)
        if (id == "#atproto_pds" || stype == "AtprotoPersonalDataServer") &&
           endpoint isa AbstractString && !isempty(endpoint)
            return rstrip(String(endpoint), '/')
        end
    end
    return nothing
end

function _session_from_output(
    out::Union{ComAtprotoServerCreateSessionOutput, ComAtprotoServerRefreshSessionOutput};
    prev::Union{Session, Nothing} = nothing,
)
    email = out isa ComAtprotoServerCreateSessionOutput ? out.email :
            (isnothing(prev) ? nothing : prev.email)
    return Session(
        out.did,
        out.handle,
        out.accessJwt,
        out.refreshJwt,
        email,
        out.active,
        out.status,
        out.didDoc,
    )
end
