#= api/types.jl =#

"""
    LexiconModel

Abstract root type for all generated AT Protocol Lexicon data models
(objects, records, and XRPC params/input/output messages).
"""
abstract type LexiconModel end

"""
    LexiconObject <: LexiconModel

Abstract base type for named AT Protocol Lexicon objects and records.

Used as the field type for Lexicon `union` and `unknown` slots: incoming JSON
objects carrying a recognized `"\$type"` discriminator deserialize directly into
the corresponding concrete subtype, while unrecognized or untyped objects fall
back to [`UnknownObject`](@ref).
"""
abstract type LexiconObject <: LexiconModel end

"""
    LexiconRecord <: LexiconObject

Abstract base type for AT Protocol repository record types (e.g.
`app.bsky.feed.post`). Records always emit their canonical `"\$type"` tag when
serialized to JSON.
"""
abstract type LexiconRecord <: LexiconObject end

"""
    LexiconMessage <: LexiconModel

Abstract base type for XRPC endpoint parameter, input, and output structs.
Unlike [`LexiconRecord`](@ref), XRPC messages do not emit a top-level `"\$type"`.
"""
abstract type LexiconMessage <: LexiconModel end
"""
    LexiconParams <: LexiconMessage

Abstract base type for XRPC `query` / `subscription` query parameter structs.
"""
abstract type LexiconParams <: LexiconMessage end

"""
    LexiconInput <: LexiconMessage

Abstract base type for XRPC `procedure` JSON request body structs.
"""
abstract type LexiconInput <: LexiconMessage end

"""
    LexiconOutput <: LexiconMessage

Abstract base type for XRPC `query` / `procedure` JSON response body structs.
"""
abstract type LexiconOutput <: LexiconMessage end

"""
    lexicon_type(::Type{<:LexiconObject}) -> Union{String, Nothing}
    lexicon_type(x::LexiconObject) -> Union{String, Nothing}

Return the canonical AT Protocol `"\$type"` string (e.g. `"app.bsky.feed.post"` or
`"app.bsky.embed.images#view"`) for a Lexicon object type or instance.
"""
lexicon_type(::Type{<:LexiconObject}) = nothing
lexicon_type(x::LexiconObject) = lexicon_type(typeof(x))

"""
    needs_type_tag(::Type{<:LexiconObject}) -> Bool

Return `true` if instances of `T` should emit a `"\$type"` field when serialized
to JSON (records, union-member objects, and `BlobRef`).
"""
needs_type_tag(::Type{<:LexiconRecord}) = true
needs_type_tag(::Type{<:LexiconObject}) = false

"""
    record_key_type(::Type{<:LexiconRecord}) -> String

Return the Lexicon record key specification for a record type (e.g. `"tid"`,
`"literal:self"`, `"nsid"`, or `"any"`).
"""
record_key_type(::Type{<:LexiconRecord}) = "any"

# Omit `nothing` optional fields on JSON serialization for all Lexicon models.
JSON.omit_null(::Type{<:LexiconModel}) = true

# Treat concrete LexiconModel structs (including 0-field singleton structs like ReasonPin)
# as JSON objects rather than falling back to stringification.
StructUtils.structlike(::Type{T}) where {T <: LexiconModel} = isconcretetype(T)

# Enable keyword-argument construction for all LexiconModel structs via a single trait
# method (avoiding hundreds of per-type covariant StructUtils.kwarg/fielddefaults methods).
StructUtils.kwarg(::StructUtils.StructStyle, ::Type{<:LexiconModel}) = true

function StructUtils.applyeach(st::JSON.JSONWriteStyle, f, x::T) where {T <: LexiconObject}
    if needs_type_tag(T)
        t = lexicon_type(T)
        if !isnothing(t)
            ret = f("\$type", t)
            ret isa StructUtils.EarlyReturn && return ret
        end
    end
    return invoke(StructUtils.applyeach, Tuple{StructUtils.StructStyle, Any, T}, st, f, x)
end

# Structural equality and hashing so Lexicon structs containing Vector/Dict fields compare by value.
function Base.:(==)(a::T, b::T) where {T <: LexiconModel}
    for i in 1:nfields(a)
        getfield(a, i) == getfield(b, i) || return false
    end
    return true
end

function Base.hash(a::T, h::UInt) where {T <: LexiconModel}
    h = hash(T, h)
    for i in 1:nfields(a)
        h = hash(getfield(a, i), h)
    end
    return h
end

# -----------------------------------------------------------------------------
# AT Protocol IPLD / Data Model Wire Primitives
# -----------------------------------------------------------------------------

"""
    CIDLink(; link::String)
    CIDLink(link::AbstractString)

IPLD CID link represented in AT Protocol DAG-JSON as `{"\$link": "<cid>"}`.
"""
Base.@kwdef struct CIDLink <: LexiconModel
    link::String
end
CIDLink(link::AbstractString) = CIDLink(; link=String(link))
StructUtils.fieldtags(::StructUtils.StructStyle, ::Type{CIDLink}) = (link = (name = Symbol("\$link"),),)

"""
    ATBytes(data::Vector{UInt8})

Raw byte array represented in AT Protocol DAG-JSON as `{"\$bytes": "<unpadded-base64>"}`.
"""
@nonstruct struct ATBytes
    data::Vector{UInt8}
end

Base.:(==)(a::ATBytes, b::ATBytes) = a.data == b.data
Base.hash(a::ATBytes, h::UInt) = hash(a.data, hash(:ATBytes, h))
Base.Vector{UInt8}(b::ATBytes) = b.data

StructUtils.lower(b::ATBytes) = Dict{String, String}("\$bytes" => rstrip(base64encode(b.data), '='))
function StructUtils.lift(::Type{ATBytes}, x::AbstractDict)
    raw = get(x, "\$bytes", nothing)
    raw isa AbstractString || throw(ArgumentError("Expected string value for '\$bytes' in ATBytes"))
    rem = mod(ncodeunits(raw), 4)
    padded = rem == 0 ? String(raw) : string(raw, '='^(4 - rem))
    return ATBytes(base64decode(padded))
end

"""
    BlobRef(; ref::CIDLink, mimeType::String, size::Int)

AT Protocol blob reference serialized as
`{"\$type": "blob", "ref": {"\$link": "..."}, "mimeType": "...", "size": ...}`.
"""
Base.@kwdef struct BlobRef <: LexiconObject
    ref::CIDLink
    mimeType::String
    size::Int
end

lexicon_type(::Type{BlobRef}) = "blob"
needs_type_tag(::Type{BlobRef}) = true

"""
    UnknownObject(type::Union{String, Nothing}, data::Dict{String, Any})
    UnknownObject(data::AbstractDict)

Fallback container for unrecognized or untyped objects encountered in open
Lexicon unions or `"unknown"` schema fields. Preserves the full raw JSON map
so data round-trips losslessly.
"""
@nonstruct struct UnknownObject <: LexiconObject
    type::Union{String, Nothing}
    data::Dict{String, Any}
end

function UnknownObject(d::AbstractDict)
    dict = Dict{String, Any}(string(k) => v for (k, v) in pairs(d))
    t = get(dict, "\$type", nothing)
    return UnknownObject(t isa AbstractString ? String(t) : nothing, dict)
end

lexicon_type(u::UnknownObject) = u.type
Base.getindex(u::UnknownObject, k) = u.data[k]
Base.get(u::UnknownObject, k, default) = get(u.data, k, default)
Base.haskey(u::UnknownObject, k) = haskey(u.data, k)
Base.keys(u::UnknownObject) = keys(u.data)
Base.convert(::Type{LexiconObject}, d::AbstractDict) = UnknownObject(d)

StructUtils.lower(u::UnknownObject) = u.data
StructUtils.lift(::Type{UnknownObject}, x::AbstractDict) = UnknownObject(x)

# -----------------------------------------------------------------------------
# XRPC Endpoint Specifications & Global Registries
# -----------------------------------------------------------------------------

"""
    EndpointError(name, description)

Declared XRPC error code from a Lexicon endpoint definition.
"""
struct EndpointError
    name::String
    description::Union{String, Nothing}
end

"""
    QueryEndpoint

Metadata for an XRPC `query` (`GET /xrpc/<nsid>`) endpoint generated from a Lexicon.
"""
struct QueryEndpoint
    nsid::NSID
    description::Union{String, Nothing}
    params::Union{DataType, Nothing}
    output::Union{DataType, Nothing}
    output_encoding::Union{String, Nothing}
    errors::Vector{EndpointError}
end

"""
    ProcedureEndpoint

Metadata for an XRPC `procedure` (`POST /xrpc/<nsid>`) endpoint generated from a Lexicon.
"""
struct ProcedureEndpoint
    nsid::NSID
    description::Union{String, Nothing}
    input::Union{DataType, Nothing}
    input_encoding::Union{String, Nothing}
    output::Union{DataType, Nothing}
    output_encoding::Union{String, Nothing}
    errors::Vector{EndpointError}
end

"""
    SubscriptionEndpoint

Metadata for an XRPC `subscription` (WebSocket `/xrpc/<nsid>`) endpoint generated from a Lexicon.
"""
struct SubscriptionEndpoint
    nsid::NSID
    description::Union{String, Nothing}
    params::Union{DataType, Nothing}
    message::Union{DataType, Nothing}
    errors::Vector{EndpointError}
end

"""
    LEXICON_TYPES

Registry mapping canonical AT Protocol `"\$type"` strings (e.g. `"app.bsky.feed.post"`,
`"app.bsky.embed.images#view"`, `"blob"`) to their concrete Julia `DataType`.
"""
const LEXICON_TYPES = Dict{String, DataType}("blob" => BlobRef)

"""
    LEXICON_ENDPOINTS

Registry mapping XRPC endpoint NSID strings (e.g. `"app.bsky.feed.getAuthorFeed"`)
to their [`QueryEndpoint`](@ref), [`ProcedureEndpoint`](@ref), or
[`SubscriptionEndpoint`](@ref) specification.
"""
const LEXICON_ENDPOINTS = Dict{String, Union{QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint}}()

"""
    LEXICON_TOKENS

Registry mapping AT Protocol Lexicon token identifiers to their canonical string values.
"""
const LEXICON_TOKENS = Dict{String, String}()

function _extract_type_tag(src)
    tag = Ref{Union{String, Nothing}}(nothing)
    StructUtils.applyeach(src) do k, v
        if k == "\$type"
            if v isa JSON.LazyValue
                if JSON.gettype(v) == JSON.JSONTypes.STRING
                    tag[] = JSON.parse(v, String)
                end
            elseif v isa AbstractString
                tag[] = String(v)
            end
            return StructUtils.EarlyReturn(nothing)
        end
    end
    return tag[]
end

JSON.@choosetype LexiconObject function (src)
    t = _extract_type_tag(src)
    return isnothing(t) ? UnknownObject : get(LEXICON_TYPES, t, UnknownObject)
end
