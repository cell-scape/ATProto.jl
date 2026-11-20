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

"""
    save_session(path::AbstractString, s::Session) -> String

Persist an authenticated [`Session`](@ref) as JSON to `path` (creating parent
directories if needed and restricting permissions to `0o600` on Unix systems).
"""
function save_session(path::AbstractString, s::Session)::String
    dir = dirname(abspath(path))
    isdir(dir) || mkpath(dir)
    payload = Dict{String, Any}(
        "did" => String(s.did),
        "handle" => String(s.handle),
        "access_jwt" => s.access_jwt,
        "refresh_jwt" => s.refresh_jwt,
    )
    !isnothing(s.email) && (payload["email"] = s.email)
    !isnothing(s.active) && (payload["active"] = s.active)
    !isnothing(s.status) && (payload["status"] = s.status)
    if s.did_doc isa UnknownObject
        payload["did_doc"] = s.did_doc.data
    end
    tmp = string(path, ".tmp.", getpid())
    write(tmp, JSON.json(payload))
    try
        Sys.isunix() && chmod(tmp, 0o600)
    catch
    end
    mv(tmp, path; force = true)
    return String(path)
end

"""
    load_session(path::AbstractString) -> Session

Load a previously persisted [`Session`](@ref) JSON file created by
[`save_session`](@ref).
"""
function load_session(path::AbstractString)::Session
    raw = JSON.parsefile(path, Dict{String, Any})
    did_val = get(raw, "did", nothing)
    handle_val = get(raw, "handle", nothing)
    access_val = get(raw, "access_jwt", get(raw, "accessJwt", nothing))
    refresh_val = get(raw, "refresh_jwt", get(raw, "refreshJwt", nothing))
    (did_val isa AbstractString && handle_val isa AbstractString &&
     access_val isa AbstractString && refresh_val isa AbstractString) ||
        throw(AuthError("Invalid session file at $path: missing required fields"))
    did_doc_raw = get(raw, "did_doc", get(raw, "didDoc", nothing))
    did_doc = did_doc_raw isa AbstractDict ? UnknownObject(did_doc_raw) : nothing
    return Session(
        did = String(did_val),
        handle = String(handle_val),
        access_jwt = String(access_val),
        refresh_jwt = String(refresh_val),
        email = get(raw, "email", nothing),
        active = get(raw, "active", nothing),
        status = get(raw, "status", nothing),
        did_doc = did_doc,
    )
end
