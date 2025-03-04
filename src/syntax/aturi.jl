#= syntax/aturi.jl =#

"""
const ATP_URI_RX::Regex

Regex for an ATProto URI
proto - did - name - path - query - hash
"""
const ATP_URI_RX = r"^(at:\/\/)?((?:did:[a-z0-9:%-]+)|(?:[a-z0-9][a-z0-9.:-]*))(\/[^?#\s]*)?(\?[^#\s]+)?(#[^\s]+)?$"

const ATP_VALID_URI_RX = r"^at:\/\/(?<authority>[a-zA-Z0-9._:%-]+)(\/(?<collection>[a-zA-Z0-9-.]+)(\/(?<rkey>[a-zA-Z0-9._~:@!$&%')(*+,;=-]+))?)?(#(?<fragment>\/[a-zA-Z0-9._~:@!$&%')(*+,;=\-[\]/\\]*))?$"

"""
const RELATIVE_RX::Regex

Regex for relative ATproto path
path - query - hash
"""
const RELATIVE_RX = r"^(\/[^?#\s]*)?(\?[^#\s]+)?(#[^\s]+)?$"

const ATP_URI_CHARS = r"^[a-zA-Z0-9._~:@!$&')(*+,;=%/-]*$"

@kwdef mutable struct AtUri
    hash::String = ""
    host::String = "" 
    pathname::String = ""
    searchparams::String = ""

    AtUri(hash, host, pathname, searchparams) = new(hash, host, pathname, searchparams)
end

protocol(aturi::AtUri)::String = "at:"
origin(aturi::AtUri)::String = string("at://", aturi.host)
hostname(aturi::AtUri)::String = aturi.host
hostname!(aturi::AtUri, host::String) = aturi.host = host
search(aturi::AtUri)::String = aturi.searchparams
search!(aturi::AtUri, searchparams::String) = aturi.searchparams = searchparams
collection(aturi::AtUri) = filter(!isempty, split(aturi.pathname, '/')) |> first
function collection!(aturi::AtUri, col::String)
    parts = filter(!isempty, split(aturi.pathname, '/'))
    parts[1] = col
    aturi.pathname = join(parts, '/')
end

rkey(aturi::AtUri) = filter(!isempty, split(aturi.pathname, '/')) |> last
function rkey!(aturi::AtUri, rk)
    parts = filter(!isempty, split(aturi.pathname, '/'))
    if isempty(first(parts))
        parts[1] = "undefined"
    end
    parts[2] = rk
    aturi.pathname = join(parts, '/')
end
    

function parse_aturi(aturi)
    m = match(ATP_URI_RX, aturi)
    isnothing(m) && error("Failed to parse AtUri")
    AtUri() 
end

function is_valid_aturi(uri)
    uriparts = split(uri, '#')
    length(uriparts) > 2 && return false
    fragment = length(uriparts) == 2 ? last(uriparts) : nothing
    uri = first(uriparts)
    isnothing(match(ATP_URI_CHARS, uri)) && return false
    parts = split(uri, '/')
    (length(parts) >= 3 && first(parts) != "at:" || !isempty(parts[2])) && return false
    length(parts) < 3 && return false
    
    try
        if startswith(parts[3], "did:")
            ensure_valid_did(parts[3])
        else
            ensure_valid_handle(parts[3])
        end
    catch 
        return false
    end

    (length(parts) >= 4 && isempty(parts[3])) && return false

    try
        ensure_valid_nsid(parts[3])
    catch
        return false
    end

    (length(parts) >= 5 && isempty(parts[4])) && return false

    length(parts) >= 6 && return false

    (length(uriparts) >= 2 && isnothing(fragment)) && return false

    if !isnothing(fragment)
        (isempty(fragment) || first(fragment) != '/') && return false
        isnothing(match(ATP_URI_CHARS, fragment)) && return false
    end

    length(uri > 8192) && return false

    return true
end

function is_valid_aturi_regex(uri; pattern=ATP_VALID_URI_RX)
    m = match(pattern, uri)
    isnothing(m) && return false
    
    !haskey(m, :authority) && return false

    (is_valid_handle_regex(m[:authority]) ||  is_valid_did_regex(m[:authority])) || return false

    if haskey(m, :collection)
        is_valid_nsid_regex(m[:collection]) || return false
    end
    
    length(uri) > 8192 && return false

    return true
end