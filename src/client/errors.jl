#= client/errors.jl =#

"""
    XRPCError <: ATProtoError

Exception thrown when an XRPC server responds with a non-2xx HTTP status.

# Fields
- `status::Int`: HTTP status code (e.g. `400`, `401`, `429`, `500`).
- `error::String`: AT Protocol error code (e.g. `"ExpiredToken"`, `"InvalidRequest"`, `"RateLimitExceeded"`).
- `message::String`: Human-readable error message from the server.
- `headers::Vector{Pair{String, String}}`: Response headers.
"""
struct XRPCError <: ATProtoError
    status::Int
    error::String
    message::String
    headers::Vector{Pair{String, String}}
end

function Base.showerror(io::IO, e::XRPCError)
    print(io, "XRPCError (HTTP ", e.status)
    if !isempty(e.error)
        print(io, " ", e.error)
    end
    print(io, ")")
    if !isempty(e.message)
        print(io, ": ", e.message)
    end
end

"""
    AuthError <: ATProtoError

Exception thrown when an operation requires authentication or session refresh fails.
"""
struct AuthError <: ATProtoError
    message::String
end

Base.showerror(io::IO, e::AuthError) = print(io, "AuthError: ", e.message)

function _parse_xrpc_error(resp::HTTP.Response)
    hdrs = Pair{String, String}[String(k) => String(v) for (k, v) in resp.headers]
    body_str = String(copy(resp.body))
    err_name = ""
    err_msg = ""

    if !isempty(body_str)
        try
            parsed = JSON.parse(body_str)
            if parsed isa AbstractDict
                e = get(parsed, "error", nothing)
                m = get(parsed, "message", nothing)
                e isa AbstractString && (err_name = String(e))
                m isa AbstractString && (err_msg = String(m))
            else
                err_msg = body_str
            end
        catch
            err_msg = body_str
        end
    end

    if isempty(err_name)
        err_name = resp.status == 429 ? "RateLimitExceeded" :
                   resp.status == 401 ? "AuthenticationRequired" :
                   resp.status == 404 ? "NotFound" :
                   "HTTP$(resp.status)"
    end

    return XRPCError(Int(resp.status), err_name, err_msg, hdrs)
end

_is_expired_token_error(e::XRPCError) =
    (e.status == 400 || e.status == 401) && e.error == "ExpiredToken"
