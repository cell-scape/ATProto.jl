# atproto-specific data extraction. Port of `packages/identity/src/did/atproto-data.ts`
# and the getters in @atproto/common-web.

"Get the DID from a document (`doc.id`)."
get_did(doc::DidDocument)::String = doc.id

"""
    get_handle(doc) -> Union{String, Nothing}

The first `alsoKnownAs` entry with an `at://` prefix, as a handle; `nothing`
when absent.
"""
function get_handle(doc::DidDocument)::Union{String,Nothing}
    doc.also_known_as === nothing && return nothing
    for aka in doc.also_known_as
        if startswith(aka, "at://")
            handle = aka[nextind(aka, 1, 5):end]
            isempty(handle) && return nothing
            return handle
        end
    end
    return nothing
end

"""
    get_signing_key(doc) -> Union{String, Nothing}

The `did:key:z...` form of the `#atproto` verification method's key, or
`nothing` when absent. Handles the Multikey, EcdsaSecp256r1, and
EcdsaSecp256k1 verification method types (as PLC documents use).
"""
function get_signing_key(doc::DidDocument)::Union{String,Nothing}
    doc.verification_method === nothing && return nothing
    for vm in doc.verification_method
        if endswith(vm.id, "#atproto")
            vm.public_key_multibase === nothing && return nothing
            return _multibase_to_did_key(vm.type, vm.public_key_multibase)
        end
    end
    return nothing
end

function _multibase_to_did_key(vm_type::String, multibase_str::String)::Union{String,Nothing}
    try
        if vm_type == "Multikey"
            parsed = parse_multikey(multibase_str)
            return format_did_key(parsed.jwt_alg, parsed.key_bytes)
        elseif vm_type == "EcdsaSecp256r1VerificationKey2019"
            key_bytes = multibase_to_bytes(multibase_str)
            return format_did_key("ES256", key_bytes)
        elseif vm_type == "EcdsaSecp256k1VerificationKey2019"
            key_bytes = multibase_to_bytes(multibase_str)
            return format_did_key("ES256K", key_bytes)
        end
    catch
        return nothing
    end
    return nothing
end

function _service_by_id_suffix(doc::DidDocument, suffix::String)::Union{DidService,Nothing}
    doc.service === nothing && return nothing
    for s in doc.service
        endswith(s.id, suffix) && return s
    end
    return nothing
end

"PDS endpoint from the `#atproto_pds` service, if present (URL string)."
function get_pds_endpoint(doc::DidDocument)::Union{String,Nothing}
    s = _service_by_id_suffix(doc, "#atproto_pds")
    s === nothing && return nothing
    return s.service_endpoint isa String ? s.service_endpoint : nothing
end

"Notification endpoint from the `#bsky_notif` service, if present."
function get_notif_endpoint(doc::DidDocument)::Union{String,Nothing}
    s = _service_by_id_suffix(doc, "#bsky_notif")
    s === nothing && return nothing
    return s.service_endpoint isa String ? s.service_endpoint : nothing
end

"Feed generator endpoint from the `#bsky_fg` service, if present."
function get_feed_gen_endpoint(doc::DidDocument)::Union{String,Nothing}
    s = _service_by_id_suffix(doc, "#bsky_fg")
    s === nothing && return nothing
    return s.service_endpoint isa String ? s.service_endpoint : nothing
end

"""
    AtprotoData

The atproto-relevant fields of a DID document: DID, signing key (`did:key`),
handle, and PDS endpoint.
"""
struct AtprotoData
    did::String
    signing_key::String
    handle::String
    pds::String
end

"""
    parse_to_atproto_document(doc) -> NamedTuple

Extract `(did, signing_key, handle, pds)` — any field may be `nothing`.
"""
parse_to_atproto_document(doc::DidDocument) = (
    did = get_did(doc),
    signing_key = get_signing_key(doc),
    handle = get_handle(doc),
    pds = get_pds_endpoint(doc),
)

"""
    ensure_atproto_data(doc) -> AtprotoData

Like [`parse_to_atproto_document`](@ref) but requires all fields, throwing
`ArgumentError` for missing ones.
"""
function ensure_atproto_data(doc::DidDocument)::AtprotoData
    data = parse_to_atproto_document(doc)
    data.did === nothing && throw(ArgumentError("Could not parse id from doc"))
    data.signing_key === nothing && throw(ArgumentError("Could not parse signingKey from doc"))
    data.handle === nothing && throw(ArgumentError("Could not parse handle from doc"))
    data.pds === nothing && throw(ArgumentError("Could not parse pds from doc"))
    return AtprotoData(data.did, data.signing_key, data.handle, data.pds)
end
