# DID document model & parsing. Port of `packages/identity` + the
# `didDocument` schema from @atproto/common-web.

"""
    DidVerificationMethod

A W3C DID verification method entry.
"""
struct DidVerificationMethod
    id::String
    type::String
    controller::String
    public_key_multibase::Union{String,Nothing}
end

"""
    DidService

A W3C DID service entry (`id`, `type`, `serviceEndpoint`).
"""
struct DidService
    id::String
    type::String
    service_endpoint::Union{String,Dict{String,Any}}
end

"""
    DidDocument

A parsed DID document. Only the fields atproto consumes are modeled:
`id`, `alsoKnownAs`, `verificationMethod`, `service`, `authentication`
(stored raw, as references or embedded methods).
"""
struct DidDocument
    id::String
    also_known_as::Union{Vector{String},Nothing}
    verification_method::Union{Vector{DidVerificationMethod},Nothing}
    service::Union{Vector{DidService},Nothing}
    authentication::Union{Vector{Any},Nothing}

    function DidDocument(id::String,
                         also_known_as::Union{Vector{String},Nothing},
                         verification_method::Union{Vector{DidVerificationMethod},Nothing},
                         service::Union{Vector{DidService},Nothing},
                         authentication::Union{Vector{Any},Nothing})
        return new(id, also_known_as, verification_method, service, authentication)
    end
end

function _parse_verification_method(entry)::DidVerificationMethod
    entry isa AbstractDict ||
        throw(ArgumentError("verificationMethod entries must be objects"))
    haskey(entry, "id") && haskey(entry, "type") && haskey(entry, "controller") ||
        throw(ArgumentError("verificationMethod requires id, type, controller"))
    pk = get(entry, "publicKeyMultibase", nothing)
    return DidVerificationMethod(
        String(entry["id"]),
        String(entry["type"]),
        String(entry["controller"]),
        pk === nothing ? nothing : String(pk),
    )
end

function _parse_service(entry)::DidService
    entry isa AbstractDict ||
        throw(ArgumentError("service entries must be objects"))
    haskey(entry, "id") && haskey(entry, "type") && haskey(entry, "serviceEndpoint") ||
        throw(ArgumentError("service requires id, type, serviceEndpoint"))
    ep = entry["serviceEndpoint"]
    endpoint = ep isa AbstractString ? String(ep) :
               ep isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in ep) :
               throw(ArgumentError("serviceEndpoint must be a string or object"))
    return DidService(String(entry["id"]), String(entry["type"]), endpoint)
end

"""
    parse_did_document(did, doc) -> DidDocument

Parse and validate a DID document (`doc` as a `Dict` from JSON). The
document `id` must match `did`. Throws `ArgumentError` on malformed
documents and `PoorlyFormattedDidDocumentError` when the id does not match.
"""
function parse_did_document(did::AbstractString, doc::AbstractDict)::DidDocument
    # basic DID syntax must hold for the document id
    is_atproto_did(did) || startswith(did, "did:") ||
        throw(PoorlyFormattedDidError(String(did)))

    haskey(doc, "id") && doc["id"] isa AbstractString ||
        throw(ArgumentError("DID document requires a string id"))
    String(doc["id"]) != String(did) &&
        throw(PoorlyFormattedDidDocumentError(
            "document id $(doc["id"]) does not match requested DID $did"))

    local aka::Union{Vector{String},Nothing} = if haskey(doc, "alsoKnownAs")
        raw = doc["alsoKnownAs"]
        raw isa AbstractVector || throw(ArgumentError("alsoKnownAs must be an array"))
        aka_vec = String[String(x) for x in raw]
        aka_vec::Vector{String}
    else
        nothing
    end

    local vm::Union{Vector{DidVerificationMethod},Nothing} = if haskey(doc, "verificationMethod")
        raw = doc["verificationMethod"]
        raw isa AbstractVector || throw(ArgumentError("verificationMethod must be an array"))
        vm_vec = DidVerificationMethod[_parse_verification_method(e) for e in raw]
        vm_vec::Vector{DidVerificationMethod}
    else
        nothing
    end

    local service::Union{Vector{DidService},Nothing} = if haskey(doc, "service")
        raw = doc["service"]
        raw isa AbstractVector || throw(ArgumentError("service must be an array"))
        entries = DidService[_parse_service(e) for e in raw]
        # duplicate service ids are not allowed
        seen = Set{String}()
        for s in entries
            full = startswith(s.id, "#") ? did * s.id : s.id
            full in seen && throw(ArgumentError("duplicate service id $(s.id)"))
            push!(seen, full)
        end
        entries::Vector{DidService}
    else
        nothing
    end

    local auth::Union{Vector{Any},Nothing} = if haskey(doc, "authentication")
        raw = doc["authentication"]
        raw isa AbstractVector || throw(ArgumentError("authentication must be an array"))
        auth_vec = Any[x for x in raw]
        auth_vec::Vector{Any}
    else
        nothing
    end

    return DidDocument(String(did), aka, vm, service, auth)
end

"Parse a DID document from raw JSON bytes."
parse_did_document(did::AbstractString, body::AbstractVector{UInt8}) =
    parse_did_document(did, JSON.parse(String(copy(body))))
