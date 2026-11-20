#= syntax/aturi.jl =#

"""
    ATP_VALID_URI_RX

Regular expression matching a valid strict AT Protocol URI (excluding length and
authority/collection/rkey inner validation).
"""
const ATP_VALID_URI_RX = r"^at:\/\/(?<authority>[a-zA-Z0-9._:%-]+)(\/(?<collection>[a-zA-Z0-9-.]+)(\/(?<rkey>[a-zA-Z0-9._~:@!$&%')(*+,;=-]+))?)?(#(?<fragment>\/[a-zA-Z0-9._~:@!$&%')(*+,;=\-[\]/\\]*))?\z"

"""
    ATP_URI_CHARS

Regular expression matching allowed ASCII characters in the base portion of an AT-URI.
"""
const ATP_URI_CHARS = r"^[a-zA-Z0-9._~:@!$&%')(*+,;=%/-]*\z"

"""
    ATP_FRAGMENT_CHARS

Regular expression matching allowed ASCII characters in an AT-URI fragment.
"""
const ATP_FRAGMENT_CHARS = r"^\/[a-zA-Z0-9._~:@!$&%')(*+,;=\-[\]/\\]*\z"

@inline function _is_aturi_fragment_byte(b::UInt8)
    _is_ascii_alnum(b) && return true
    return b == UInt8('.') || b == UInt8('_') || b == UInt8('~') || b == UInt8(':') ||
           b == UInt8('@') || b == UInt8('!') || b == UInt8('$') || b == UInt8('&') ||
           b == UInt8('%') || b == UInt8('\'') || b == UInt8(')') || b == UInt8('(') ||
           b == UInt8('*') || b == UInt8('+') || b == UInt8(',') || b == UInt8(';') ||
           b == UInt8('=') || b == UInt8('-') || b == UInt8('[') || b == UInt8(']') ||
           b == UInt8('/') || b == UInt8('\\')
end

@inline function _find_byte(cu, target::UInt8, start::Int, stop::Int)
    @inbounds for i in start:stop
        cu[i] == target && return i
    end
    return 0
end

function _validate_aturi_fragment_bytes(cu, start::Int, stop::Int)
    start > stop && return "AT-URI fragment cannot be empty"
    @inbounds cu[start] == UInt8('/') || return "AT-URI fragment must start with '/'"
    @inbounds for i in (start + 1):stop
        _is_aturi_fragment_byte(cu[i]) ||
            return "Disallowed characters in AT-URI fragment"
    end
    return nothing
end

_validate_aturi_fragment(frag::Union{String, SubString{String}}) =
    _validate_aturi_fragment_bytes(codeunits(frag), 1, ncodeunits(frag))

_validate_aturi_fragment(frag::AbstractString) = _validate_aturi_fragment(String(frag))

function _validate_aturi_bytes(cu, start::Int, stop::Int)
    n = stop - start + 1
    n <= 0 && return "AT-URI cannot be empty"
    n > 8192 && return "AT-URI is too long (8192 characters max)"
    @inbounds if n < 5 || cu[start] != UInt8('a') || cu[start + 1] != UInt8('t') ||
                 cu[start + 2] != UInt8(':') || cu[start + 3] != UInt8('/') || cu[start + 4] != UInt8('/')
        return "AT-URI must start with 'at://'"
    end

    base_start = start + 5
    hash_idx = _find_byte(cu, UInt8('#'), base_start, stop)
    if hash_idx == 0
        base_stop = stop
    else
        _find_byte(cu, UInt8('#'), hash_idx + 1, stop) == 0 ||
            return "AT-URI can have at most one '#' fragment delimiter"
        frag_err = _validate_aturi_fragment_bytes(cu, hash_idx + 1, stop)
        isnothing(frag_err) || return frag_err
        base_stop = hash_idx - 1
    end

    base_start > base_stop && return "AT-URI requires an authority (DID or handle)"

    slash1 = _find_byte(cu, UInt8('/'), base_start, base_stop)
    if slash1 == 0
        auth_stop = base_stop
        col_start = 0
        col_stop = 0
        rk_start = 0
        rk_stop = 0
    else
        auth_stop = slash1 - 1
        slash1 == base_stop && return "AT-URI cannot end with a trailing '/'"
        slash2 = _find_byte(cu, UInt8('/'), slash1 + 1, base_stop)
        if slash2 == 0
            col_start = slash1 + 1
            col_stop = base_stop
            rk_start = 0
            rk_stop = 0
        else
            col_start = slash1 + 1
            col_stop = slash2 - 1
            rk_start = slash2 + 1
            rk_stop = base_stop
            col_start > col_stop && return "AT-URI collection segment cannot be empty"
            rk_start > rk_stop && return "AT-URI record key segment cannot be empty"
            _find_byte(cu, UInt8('/'), rk_start, rk_stop) == 0 ||
                return "AT-URI path can have at most authority, collection, and record key"
        end
    end

    base_start > auth_stop && return "AT-URI authority cannot be empty"

    is_did = @inbounds (auth_stop - base_start + 1 >= 4) &&
        cu[base_start] == UInt8('d') && cu[base_start + 1] == UInt8('i') &&
        cu[base_start + 2] == UInt8('d') && cu[base_start + 3] == UInt8(':')
    auth_err = is_did ?
        _validate_did_bytes(cu, base_start, auth_stop) :
        _validate_handle_bytes(cu, base_start, auth_stop)
    isnothing(auth_err) || return auth_err

    if col_start != 0
        col_err = _validate_nsid_bytes(cu, col_start, col_stop)
        isnothing(col_err) || return col_err
    end

    if rk_start != 0
        rk_err = _validate_record_key_bytes(cu, rk_start, rk_stop)
        isnothing(rk_err) || return rk_err
    end

    return nothing
end

_validate_aturi(uri::Union{String, SubString{String}}) =
    _validate_aturi_bytes(codeunits(uri), 1, ncodeunits(uri))

_validate_aturi(uri::AbstractString) = _validate_aturi(String(uri))

function _split_aturi_raw(uri::Union{String, SubString{String}})
    err = _validate_aturi(uri)
    isnothing(err) || return (nothing, err)

    cu = codeunits(uri)
    n = ncodeunits(uri)
    hash_idx = _find_byte(cu, UInt8('#'), 6, n)
    if hash_idx == 0
        base_stop = n
        frag = nothing
    else
        base_stop = hash_idx - 1
        frag = SubString(uri, hash_idx + 1, n)
    end

    slash1 = _find_byte(cu, UInt8('/'), 6, base_stop)
    if slash1 == 0
        auth_str = SubString(uri, 6, base_stop)
        col_str = nothing
        rkey_str = nothing
    else
        auth_str = SubString(uri, 6, slash1 - 1)
        slash2 = _find_byte(cu, UInt8('/'), slash1 + 1, base_stop)
        if slash2 == 0
            col_str = SubString(uri, slash1 + 1, base_stop)
            rkey_str = nothing
        else
            col_str = SubString(uri, slash1 + 1, slash2 - 1)
            rkey_str = SubString(uri, slash2 + 1, base_stop)
        end
    end

    return ((auth_str, col_str, rkey_str, frag), nothing)
end

_split_aturi_raw(uri::AbstractString) = _split_aturi_raw(String(uri))

"""
    is_valid_aturi(uri::AbstractString) -> Bool

Return `true` if `uri` conforms to the AT Protocol AT-URI specification.

# Examples
```jldoctest
julia> ATProto.Syntax.is_valid_aturi("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y")
true

julia> ATProto.Syntax.is_valid_aturi("at://bsky.app")
true

julia> ATProto.Syntax.is_valid_aturi("https://bsky.app")
false
```
"""
is_valid_aturi(uri::AbstractString) = isnothing(_validate_aturi(uri))

"""
    ensure_valid_aturi(uri::AbstractString) -> Nothing

Validate `uri` against the AT Protocol AT-URI specification, throwing a
[`SyntaxError`](@ref) if invalid.
"""
function ensure_valid_aturi(uri::AbstractString)
    err = _validate_aturi(uri)
    isnothing(err) || throw(SyntaxError(:aturi, String(uri), err))
    return nothing
end

"""
    is_valid_aturi_regex(uri::AbstractString; pattern=ATP_VALID_URI_RX) -> Bool

Validate an AT-URI using `pattern`, the 8192-byte limit, and component validation.
"""
function is_valid_aturi_regex(uri::AbstractString; pattern::Regex=ATP_VALID_URI_RX)
    ncodeunits(uri) > 8192 && return false
    m = match(pattern, uri)
    isnothing(m) && return false

    auth = m[:authority]
    isnothing(auth) && return false
    (is_valid_did_regex(auth) || is_valid_handle_regex(auth)) || return false

    col = m[:collection]
    if !isnothing(col)
        is_valid_nsid_regex(col) || return false
    end

    rk = m[:rkey]
    if !isnothing(rk)
        is_valid_record_key(rk) || return false
    end

    return true
end

"""
    AtUri(uri::AbstractString)
    AtUri(authority; collection=nothing, rkey=nothing, fragment=nothing)

Immutable, validated AT Protocol URI (`at://<authority>[/<collection>[/<rkey>]][#<fragment>]`).

Can also be constructed with `parse(AtUri, s)`, `tryparse(AtUri, s)`, or the
compile-time string macro `at"at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y"`.
"""
struct AtUri
    authority::Union{DID, Handle}
    collection::Union{NSID, Nothing}
    rkey::Union{RecordKey, Nothing}
    fragment::Union{String, Nothing}

    AtUri(::_Unchecked, authority::Union{DID, Handle},
          collection::Union{NSID, Nothing},
          rkey::Union{RecordKey, Nothing},
          fragment::Union{String, Nothing}) = new(authority, collection, rkey, fragment)

    function AtUri(authority::Union{DID, Handle};
                   collection::Union{NSID, AbstractString, Nothing}=nothing,
                   rkey::Union{RecordKey, TID, AbstractString, Nothing}=nothing,
                   fragment::Union{AbstractString, Nothing}=nothing)
        col = isnothing(collection) ? nothing : convert(NSID, collection)
        rk = isnothing(rkey) ? nothing : convert(RecordKey, rkey)
        !isnothing(rk) && isnothing(col) &&
            throw(SyntaxError(:aturi, string(rk), "AT-URI cannot specify a record key without a collection"))

        frag = if isnothing(fragment)
            nothing
        else
            frag_s = String(fragment)
            frag_err = _validate_aturi_fragment(frag_s)
            isnothing(frag_err) || throw(SyntaxError(:aturi, frag_s, frag_err))
            frag_s
        end

        return new(authority, col, rk, frag)
    end
end

function AtUri(uri::AbstractString)
    parsed, err = _split_aturi_raw(uri)
    isnothing(err) || throw(SyntaxError(:aturi, String(uri), err))
    auth_str, col_str, rkey_str, frag_str = parsed
    auth = startswith(auth_str, "did:") ?
        DID(_Unchecked(), String(auth_str)) :
        Handle(_Unchecked(), lowercase(String(auth_str)))
    col = if isnothing(col_str)
        nothing
    else
        normalized, last_dot = _normalize_nsid_parts(col_str)
        NSID(_Unchecked(), normalized, last_dot)
    end
    rk = isnothing(rkey_str) ? nothing : RecordKey(_Unchecked(), String(rkey_str))
    frag = isnothing(frag_str) ? nothing : String(frag_str)
    return AtUri(_Unchecked(), auth, col, rk, frag)
end

"""
    parse_aturi(uri::AbstractString) -> AtUri

Parse and validate an AT-URI string into an [`AtUri`](@ref). Alias for `parse(AtUri, uri)`.
"""
parse_aturi(uri::AbstractString) = parse(AtUri, uri)

protocol(::AtUri) = "at:"
origin(u::AtUri) = string("at://", u.authority)
authority(u::AtUri) = u.authority
hostname(u::AtUri) = string(u.authority)
collection(u::AtUri) = u.collection
rkey(u::AtUri) = u.rkey
fragment(u::AtUri) = u.fragment

function Base.tryparse(::Type{AtUri}, s::AbstractString)
    parsed, err = _split_aturi_raw(s)
    isnothing(err) || return nothing
    auth_str, col_str, rkey_str, frag_str = parsed
    auth = startswith(auth_str, "did:") ?
        DID(_Unchecked(), String(auth_str)) :
        Handle(_Unchecked(), lowercase(String(auth_str)))
    col = if isnothing(col_str)
        nothing
    else
        normalized, last_dot = _normalize_nsid_parts(col_str)
        NSID(_Unchecked(), normalized, last_dot)
    end
    rk = isnothing(rkey_str) ? nothing : RecordKey(_Unchecked(), String(rkey_str))
    frag = isnothing(frag_str) ? nothing : String(frag_str)
    return AtUri(_Unchecked(), auth, col, rk, frag)
end

Base.parse(::Type{AtUri}, s::AbstractString) = AtUri(s)
Base.convert(::Type{AtUri}, s::AbstractString) = AtUri(s)
Base.convert(::Type{AtUri}, u::AtUri) = u
Base.convert(::Type{String}, u::AtUri) = String(u)
Base.String(u::AtUri) = sprint(print, u)

function Base.print(io::IO, u::AtUri)
    print(io, "at://", u.authority)
    if !isnothing(u.collection)
        print(io, '/', u.collection)
        if !isnothing(u.rkey)
            print(io, '/', u.rkey)
        end
    end
    if !isnothing(u.fragment)
        print(io, '#', u.fragment)
    end
    return nothing
end

Base.show(io::IO, u::AtUri) = print(io, "AtUri(", repr(String(u)), ")")
Base.isless(a::AtUri, b::AtUri) = isless(String(a), String(b))

StructUtils.structlike(::Type{AtUri}) = false
StructUtils.lower(u::AtUri) = String(u)
StructUtils.lift(::Type{AtUri}, x::AbstractString) = AtUri(x)

"""
    @at_str -> AtUri

Compile-time validated AT Protocol URI literal, e.g.
`at"at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y"`.
"""
macro at_str(s::String)
    return AtUri(s)
end
