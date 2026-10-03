# XRPC errors and response-type mapping. Port of `packages/xrpc/src/types.ts`.

"""
    XRPCError <: Exception

An XRPC call failure. `status` is the HTTP status code, or one of the XRPC
sentinels `1` (network/unknown failure) and `2` (invalid response).
`error` is the server's machine-readable error name, if provided.
"""
struct XRPCError <: Exception
    status::Int
    error::Union{String,Nothing}
    message::String
    headers::Vector{Pair{String,String}}

    function XRPCError(status::Integer, error::Union{AbstractString,Nothing} = nothing,
                       message::Union{AbstractString,Nothing} = nothing,
                       headers = Pair{String,String}[])
        msg = message !== nothing ? String(message) :
              error !== nothing ? String(error) : response_type_string(status)
        hdrs = Pair{String,String}[String(k) => String(v) for (k, v) in headers]
        return new(Int(status), error === nothing ? nothing : String(error), msg, hdrs)
    end
end

function Base.showerror(io::IO, err::XRPCError)
    print(io, "XRPCError(", err.status)
    err.error !== nothing && print(io, ", \"", err.error, "\"")
    print(io, "): ", err.message)
end

"Human-readable names for the XRPC response types (see ResponseType in the TS reference)."
function response_type_string(status::Integer)::String
    names = Dict(
        1 => "Unknown",
        2 => "Invalid Response",
        200 => "Success",
        400 => "Invalid Request",
        401 => "Authentication Required",
        403 => "Forbidden",
        404 => "XRPC Not Supported",
        406 => "Not Acceptable",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        429 => "Rate Limit Exceeded",
        500 => "Internal Server Error",
        501 => "Method Not Implemented",
        502 => "Upstream Failure",
        503 => "Not Enough Resources",
        504 => "Upstream Timeout",
    )
    return get(names, Int(status)) do
        if 100 <= status < 200 || 300 <= status < 400
            return "XRPC Not Supported"
        elseif 200 <= status < 300
            return "Success"
        elseif 400 <= status < 500
            return "Invalid Request"
        else
            return "Internal Server Error"
        end
    end
end

"""
    XRPCResponse

A successful XRPC call result: decoded `data` (JSON objects, text, or raw
bytes depending on the content type) plus response `headers`.
"""
struct XRPCResponse
    data::Any
    headers::Vector{Pair{String,String}}
end

"Extract the error/message fields from a JSON error body, if that's what it is."
function error_body_fields(data::Any)::Union{Tuple{String,String},Nothing}
    data isa AbstractDict || return nothing
    haskey(data, "error") || haskey(data, "message") || return nothing
    err = get(data, "error", nothing)
    msg = get(data, "message", nothing)
    (err isa AbstractString || msg isa AbstractString) || return nothing
    return (err isa AbstractString ? String(err) : "",
            msg isa AbstractString ? String(msg) : "")
end
