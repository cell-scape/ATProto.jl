# AT-URI parsing and construction. Port of `packages/syntax/src/aturi.ts`.
#
# Format: at://<authority>/<collection>/<rkey>?<query>#<fragment>
# where <authority> is a DID or handle, <collection> an NSID, and <rkey> a
# record key. The "at://" scheme prefix is optional when parsing and always
# included when serializing.

#        proto-    --did--------------   --name----------------   --path----   --query--   --hash--
const ATP_URI_REGEX = r"\A(?:at://)?((?:did:[a-z0-9:%-]+)|(?:[a-z0-9][a-z0-9.:-]*))(/[^?#\s]*)?(\?[^#\s]+)?(#[^\s]+)?\z"i
const RELATIVE_REGEX = r"\A(/[^?#\s]*)?(\?[^#\s]+)?(#[^\s]+)?\z"i

"""
    AtURI

An immutable, parsed AT-URI with a validated host (DID or handle).

Fields:
- `host::String` — authority: a DID or handle
- `pathname::String` — e.g. `"/app.bsky.feed.post/3jx2h5l2b1c2p"` (or `""`)
- `search_params::Vector{Pair{String,String}}` — decoded query parameters
- `fragment::String` — with a leading `'#'`, or `""`

Constructors:
- `AtURI(uri::AbstractString)` — parse (throws [`InvalidAtUriError`](@ref))
- `AtURI(uri::AbstractString; base)` — parse relative to a base AT-URI
- `AtURI(host, collection, rkey)` — build from parts (via [`at_uri`](@ref))
"""
struct AtURI
    host::String
    pathname::String
    search_params::Vector{Pair{String,String}}
    fragment::String

    function AtURI(host::AbstractString, pathname::AbstractString,
                   search_params::Vector{Pair{String,String}},
                   fragment::AbstractString)
        ensure_valid_at_identifier(host)
        return new(String(host), String(pathname), search_params, String(fragment))
    end
end

AtURI(uri::AtURI) = uri

# --- internals ---------------------------------------------------------------

function _parse_at_uri(str::AbstractString)
    m = match(ATP_URI_REGEX, str)
    m === nothing && throw(InvalidAtUriError("Invalid AT uri: $str"))
    return (;
        host = String(m[1]),
        pathname = m[2] === nothing ? "" : String(m[2]),
        query = m[3] === nothing ? "" : String(m[3]),
        fragment = m[4] === nothing ? "" : String(m[4]),
    )
end

function _parse_relative(str::AbstractString)
    m = match(RELATIVE_REGEX, str)
    m === nothing && throw(InvalidAtUriError("Invalid path: $str"))
    return (;
        pathname = m[1] === nothing ? "" : String(m[1]),
        query = m[2] === nothing ? "" : String(m[2]),
        fragment = m[3] === nothing ? "" : String(m[3]),
    )
end

"Percent-decode a URLSearchParams component ('+' means space)."
function _form_decode(s::AbstractString)::String
    out = IOBuffer()
    i = firstindex(s)
    ncodeunits(s) == 0 && return ""
    while i <= ncodeunits(s)
        c = s[i]
        if c == '+'
            print(out, ' ')
            i = nextind(s, i)
        elseif c == '%' && i + 2 <= ncodeunits(s)
            hex = String(s[nextind(s, i):nextind(s, i, 2)])
            v = tryparse(UInt8, "0x" * hex)
            if v === nothing
                print(out, c)
                i = nextind(s, i)
            else
                write(out, v)
                i = nextind(s, i, 3)
            end
        else
            print(out, c)
            i = nextind(s, i)
        end
    end
    return String(take!(out))
end

"Percent-encode a URLSearchParams component (space becomes '+')."
function _form_encode(s::AbstractString)::String
    out = IOBuffer()
    for b in codeunits(s)
        if (0x30 <= b <= 0x39) || (0x41 <= b <= 0x5a) || (0x61 <= b <= 0x7a) ||
           b in (0x2a, 0x2d, 0x2e, 0x5f, 0x7e)  # * - . _ ~
            write(out, b)
        elseif b == 0x20
            write(out, '+')
        else
            print(out, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    return String(take!(out))
end

_parse_params(q::AbstractString) = begin
    q = startswith(q, "?") ? q[2:end] : q
    Pair{String,String}[
        let kv = split(p, "="; limit = 2)
            _form_decode(String(kv[1])) => _form_decode(length(kv) > 1 ? String(kv[2]) : "")
        end
        for p in split(q, "&") if !isempty(p)
    ]
end

_serialize_params(params::Vector{Pair{String,String}}) =
    join((_form_encode(k) * "=" * _form_encode(v) for (k, v) in params), "&")

# --- constructors ------------------------------------------------------------

"""
    AtURI(uri::AbstractString; base=nothing)

Parse an AT-URI string. When `base` (an `AtURI` or AT-URI string) is given,
`uri` is parsed as a relative reference and resolved against the base host.
Throws [`InvalidAtUriError`](@ref) (or the underlying DID/handle error) on
invalid input.
"""
function AtURI(uri::AbstractString; base = nothing)
    if base === nothing
        p = _parse_at_uri(uri)
        return AtURI(p.host, p.pathname, _parse_params(p.query), p.fragment)
    end
    p = _parse_relative(uri)
    host = base isa AtURI ? base.host : _parse_at_uri(String(base)).host
    return AtURI(host, p.pathname, _parse_params(p.query), p.fragment)
end

"""
    at_uri(host, collection="", rkey="") -> AtURI

Build an [`AtURI`](@ref) from a host (handle or DID) and optional collection
NSID and record key. Mirrors `AtUri.make` in the TypeScript reference.
"""
function at_uri(host::AbstractString, collection::AbstractString = "",
               rkey::AbstractString = "")::AtURI
    parts = String[]
    !isempty(collection) && push!(parts, String(collection))
    !isempty(rkey) && push!(parts, String(rkey))
    pathname = isempty(parts) ? "" : "/" * join(parts, "/")
    return AtURI(host, pathname, Pair{String,String}[], "")
end

# --- accessors ---------------------------------------------------------------

"Return the authority portion (DID or handle) of the AT-URI."
host(uri::AtURI)::String = uri.host

"""
    did(uri::AtURI) -> String

Return the host, requiring it to be a DID. Throws [`InvalidDidError`](@ref)
if the host is a handle.
"""
function did(uri::AtURI)::String
    is_did_identifier(uri.host) && return uri.host
    throw(InvalidDidError("AtUri \"$uri\" does not have a DID hostname"))
end

"Return `\"at://<host>\"` for the AT-URI."
origin(uri::AtURI)::String = "at://" * uri.host

"Return the serialized query string (without `?`), or `\"\"`."
query(uri::AtURI)::String = isempty(uri.search_params) ? "" : _serialize_params(uri.search_params)

"Return the pathname (e.g. `/collection/rkey`), or `\"\"`."
pathname(uri::AtURI)::String = uri.pathname

"Return the fragment with its leading `'#'`, or `\"\"`."
fragment(uri::AtURI)::String = uri.fragment

function _path_parts(uri::AtURI)::Vector{String}
    return String[p for p in split(uri.pathname, "/") if !isempty(p)]
end

"Return the first path segment (the collection NSID), or `\"\"`. Not validated."
function collection(uri::AtURI)::String
    parts = _path_parts(uri)
    return isempty(parts) ? "" : parts[1]
end

"""
    collection_safe(uri::AtURI) -> String

Return the collection, validating it as an NSID. Throws
[`InvalidNsidError`](@ref) when missing/invalid.
"""
function collection_safe(uri::AtURI)::String
    return ensure_valid_nsid(collection(uri))
end

"Return the second path segment (the record key), or `\"\"`. Not validated."
function rkey(uri::AtURI)::String
    parts = _path_parts(uri)
    return length(parts) > 1 ? parts[2] : ""
end

"""
    rkey_safe(uri::AtURI) -> String

Return the record key, validating its syntax. Throws
[`InvalidRecordKeyError`](@ref) when missing/invalid.
"""
function rkey_safe(uri::AtURI)::String
    return ensure_valid_record_key(rkey(uri))
end

# --- serialization -----------------------------------------------------------

"""
    Base.string(uri::AtURI) -> String

Serialize to canonical `at://<host>[<pathname>][?query][#fragment]` form.
The fragment keeps its leading `'#'`; a bare fragment identifier (no query
string) still round-trips.
"""
function Base.string(uri::AtURI)::String
    qs = query(uri)
    fragment = uri.fragment
    if !isempty(fragment) && !startswith(fragment, "#")
        fragment = "#" * fragment
    end
    return "at://" * uri.host * uri.pathname *
           (isempty(qs) ? "" : "?" * qs) * fragment
end

Base.print(io::IO, uri::AtURI) = print(io, string(uri))
Base.:(==)(a::AtURI, b::AtURI) = string(a) == string(b)
Base.:(==)(a::AtURI, b::AbstractString) = string(a) == b
Base.:(==)(a::AbstractString, b::AtURI) = a == string(b)
Base.hash(uri::AtURI, h::UInt) = hash(string(uri), h)
