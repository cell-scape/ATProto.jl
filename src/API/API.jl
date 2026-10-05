module API

using ..XRPC
using ..Lexicon
using ..Crypto
using ..Syntax
using ..Identity
using HTTP
using Dates
using JSON

export Agent,
    SessionAgent,
    login,
    client_of,
    did_of,
    handle_of,
    session_of,
    service_url,
    resolve_handle,
    upload_blob,
    put_record,
    delete_record,
    create_record,
    get_record,
    create_post,
    delete_post,
    OFFICIAL_LEXICONS

include("lexicons_data.jl")

"Recursively convert blob-shaped JSON objects into BlobRefs."
function _blobify(v)
    if v isa AbstractDict
        br = blob_ref_from_json(v)
        br !== nothing && return br
        return Dict{String,Any}(String(k) => _blobify(x) for (k, x) in v)
    elseif v isa AbstractVector
        return Any[_blobify(x) for x in v]
    end
    return v
end

include("agent.jl")

# --- call helpers ---------------------------------------------------------------

"Drop nothing-valued kwargs into a params dict."
function _params_dict(kwargs)
    out = Dict{String,Any}()
    for (k, v) in kwargs
        v === nothing && continue
        out[String(k)] = v
    end
    return out
end

function _call_query(client, nsid; kwargs...)
    c = client_of(client)
    params = _params_dict(kwargs)
    def = get_def_or_throw(OFFICIAL_LEXICONS, nsid)
    assert_valid_xrpc_params(OFFICIAL_LEXICONS, def, params)
    res = xrpc_get(c, nsid; params = params, param_types = param_types_for(nsid))
    data = _blobify(res.data)
    assert_valid_xrpc_output(OFFICIAL_LEXICONS, def, data)
    return data
end

function _call_proc(client, nsid; data = nothing, encoding = nothing, kwargs...)
    c = client_of(client)
    params = _params_dict(kwargs)
    def = get_def_or_throw(OFFICIAL_LEXICONS, nsid)
    assert_valid_xrpc_params(OFFICIAL_LEXICONS, def, params)
    if data !== nothing
        assert_valid_xrpc_input(OFFICIAL_LEXICONS, def, data)
        encoding === nothing && (encoding = "application/json")
    end
    res = xrpc_proc(c, nsid; data = data, encoding = encoding,
                    params = params, param_types = param_types_for(nsid))
    data = _blobify(res.data)
    assert_valid_xrpc_output(OFFICIAL_LEXICONS, def, data)
    return data
end

"Open an XRPC subscription; accepts a client, an Agent, or a URL string."
function _call_subscription(x, nsid; kwargs...)
    url = x isa AbstractString ? String(x) : service_url(x)
    params = _params_dict(kwargs)
    def = get_def_or_throw(OFFICIAL_LEXICONS, nsid)
    assert_valid_xrpc_params(OFFICIAL_LEXICONS, def, params)
    return subscribe(url, nsid; params = params, param_types = param_types_for(nsid))
end

# a plain module the generated namespaces can import from any depth
module _API_helpers
import ..API: _call_query, _call_proc, _call_subscription
end

include("namespaces.jl")

end # module
