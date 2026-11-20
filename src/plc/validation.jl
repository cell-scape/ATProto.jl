# DID method validation. Port of `packages/did/src/{methods,atproto}.ts`.

const DID_PLC_PREFIX = "did:plc:"
const DID_PLC_LENGTH = 32 # "did:plc:" + 24 base32 chars

const DID_WEB_PREFIX = "did:web:"

"""
    is_did_plc(s) -> Bool

`true` if `s` is a syntactically valid `did:plc` (prefix + 24 chars of
`[a-z2-7]`).
"""
function is_did_plc(s::AbstractString)::Bool
    length(s) == DID_PLC_LENGTH || return false
    startswith(s, DID_PLC_PREFIX) || return false
    for i in (length(DID_PLC_PREFIX)+1):DID_PLC_LENGTH
        c = s[i]
        (('a' <= c <= 'z') || ('2' <= c <= '7')) || return false
    end
    return true
end

"""
    ensure_did_plc(s) -> String

Validate `s` as a `did:plc`, returning it; throws `PoorlyFormattedDidError`.
"""
function ensure_did_plc(s::AbstractString)::String
    startswith(s, DID_PLC_PREFIX) ||
        throw(PoorlyFormattedDidError(String(s)))
    length(s) == DID_PLC_LENGTH ||
        throw(PoorlyFormattedDidError(
            "did:plc must be $DID_PLC_LENGTH characters long: $s"))
    for i in (length(DID_PLC_PREFIX)+1):DID_PLC_LENGTH
        c = s[i]
        (('a' <= c <= 'z') || ('2' <= c <= '7')) ||
            throw(PoorlyFormattedDidError("Invalid character at position $i in $s"))
    end
    return String(s)
end

"""
    build_did_web_url(did) -> String

The `https://` (or `http://` for localhost) URL a `did:web` resolves at.
Ports encoded as `%3A` are decoded into the host.
"""
function build_did_web_url(did::AbstractString)::String
    host_idx = length(DID_WEB_PREFIX) + 1
    path_idx = findnext(':', did, host_idx)
    host_enc = path_idx === nothing ? did[host_idx:end] : did[host_idx:prevind(did, path_idx)]
    host = replace(host_enc, "%3A" => ":")
    path = path_idx === nothing ? "" : replace(did[path_idx:end], ':' => '/')
    proto = (startswith(host, "localhost") && (length(host) == 9 || host[10] == ':')) ? "http" : "https"
    return "$proto://$host$path"
end

"""
    did_web_to_url(did) -> String

Like [`build_did_web_url`](@ref), validating the resulting URL is parseable.
"""
function did_web_to_url(did::AbstractString)::String
    url = build_did_web_url(did)
    host = replace(split(url, "//")[2], r"/.*" => "")
    isempty(host) && throw(PoorlyFormattedDidError("Invalid Web DID: $did"))
    occursin(r"\.", host) || occursin(r"^localhost(:\d+)?$", host) ||
        throw(PoorlyFormattedDidError("Invalid Web DID host: $did"))
    return url
end

"""
    is_did_web(s) -> Bool

`true` if `s` is a syntactically valid `did:web` (including path/port forms
that atproto itself disallows — see [`is_atproto_did`](@ref)).
"""
function is_did_web(s::AbstractString)::Bool
    startswith(s, DID_WEB_PREFIX) || return false
    msid = s[length(DID_WEB_PREFIX)+1:end]
    isempty(msid) && return false
    first(msid) == ':' && return false
    for c in msid
        (('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') ||
         c in ('.', '-', '_', ':', '%')) || return false
    end
    try
        did_web_to_url(s)
    catch
        return false
    end
    return true
end

ensure_did_web(s::AbstractString) = (is_did_web(s) || throw(PoorlyFormattedDidError(String(s))); String(s))

"Localhost DIDs may carry ports (resolved over http)."
function _is_localhost_did(did::AbstractString)::Bool
    return did == "did:web:localhost" ||
           startswith(did, "did:web:localhost:") ||
           startswith(did, "did:web:localhost%3A")
end

_is_did_web_with_path(did::AbstractString) = something(findnext(':', did, length(DID_WEB_PREFIX) + 1), 0) != 0

"Detect a %3A-encoded port (allowed only for localhost), per the TS reference."
function _is_did_web_with_https_port(did::AbstractString)::Bool
    _is_localhost_did(did) && return false
    path_idx = something(findnext(':', did, length(DID_WEB_PREFIX) + 1), 0)
    if path_idx == 0
        return occursin("%3A", did[nextind(did, 1, length(DID_WEB_PREFIX)):end])
    end
    # path component exists: an encoded colon *before* it is a port
    host_part = did[1:prevind(did, path_idx)]
    return occursin("%3A", host_part[nextind(host_part, 1, length(DID_WEB_PREFIX)):end])
end

"""
    is_atproto_did(s) -> Bool

`true` if `s` is a DID of a method atproto allows: `did:plc`, or `did:web`
without path components and without a port (except `localhost`, where
`http://localhost[:port]` is allowed). See
https://atproto.com/specs/did#blessed-did-methods
"""
function is_atproto_did(s::AbstractString)::Bool
    if startswith(s, DID_PLC_PREFIX)
        return is_did_plc(s)
    elseif startswith(s, DID_WEB_PREFIX)
        is_did_web(s) || return false
        _is_did_web_with_path(s) && return false
        _is_did_web_with_https_port(s) && return false
        return true
    end
    return false
end

"""
    ensure_atproto_did(s) -> String

Validate `s` as an atproto DID (`did:plc` or path/port-free `did:web`),
returning it; throws `UnsupportedDidMethodError` / `PoorlyFormattedDidError`.
"""
function ensure_atproto_did(s::AbstractString)::String
    if startswith(s, DID_PLC_PREFIX)
        return ensure_did_plc(s)
    elseif startswith(s, DID_WEB_PREFIX)
        ensure_did_web(s)
        _is_did_web_with_path(s) &&
            throw(PoorlyFormattedDidError("Atproto does not allow path components in Web DIDs: $s"))
        _is_did_web_with_https_port(s) &&
            throw(PoorlyFormattedDidError("Atproto does not allow port numbers in Web DIDs, except for localhost: $s"))
        return String(s)
    end
    throw(UnsupportedDidMethodError(String(s)))
end
