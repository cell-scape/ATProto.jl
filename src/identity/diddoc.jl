#= identity/diddoc.jl =#

"""
    DIDVerificationMethod

Verification method entry (e.g. `#atproto` repository signing key) inside a
[`DIDDocument`](@ref).
"""
struct DIDVerificationMethod
    id::String
    type::String
    controller::String
    publicKeyMultibase::Union{String, Nothing}
end

"""
    DIDService

Service endpoint entry (e.g. `#atproto_pds`) inside a [`DIDDocument`](@ref).
"""
struct DIDService
    id::String
    type::String
    serviceEndpoint::String
end

"""
    DIDDocument

Parsed AT Protocol DID document containing identity, `alsoKnownAs` handle URIs,
verification methods, service endpoints, and the raw JSON dictionary.
"""
struct DIDDocument
    id::DID
    alsoKnownAs::Vector{String}
    verificationMethod::Vector{DIDVerificationMethod}
    service::Vector{DIDService}
    raw::Dict{String, Any}
end

function Base.:(==)(a::DIDDocument, b::DIDDocument)
    return a.id == b.id &&
           a.alsoKnownAs == b.alsoKnownAs &&
           a.verificationMethod == b.verificationMethod &&
           a.service == b.service
end

function Base.hash(a::DIDDocument, h::UInt)
    return hash(a.service, hash(a.verificationMethod, hash(a.alsoKnownAs, hash(a.id, hash(:DIDDocument, h)))))
end

function Base.show(io::IO, doc::DIDDocument)
    print(io, "DIDDocument(id=", repr(String(doc.id)),
          ", handle=", repr(atproto_handle(doc)),
          ", pds=", repr(pds_endpoint(doc)), ")")
end

"""
    parse_did_document(raw::AbstractDict) -> DIDDocument
    parse_did_document(json_str::AbstractString) -> DIDDocument

Parse a DID document JSON string or dictionary into a typed [`DIDDocument`](@ref).
Throws [`IdentityError`](@ref) if `"id"` is missing or not a valid DID.
"""
function parse_did_document(raw_in::AbstractDict)
    raw = Dict{String, Any}(string(k) => v for (k, v) in pairs(raw_in))
    id_val = get(raw, "id", nothing)
    id_val isa AbstractString || throw(IdentityError("<unknown>", "DID document missing string 'id' field"))
    did = tryparse(DID, id_val)
    isnothing(did) && throw(IdentityError(String(id_val), "DID document 'id' is not a valid DID"))

    aka = String[]
    aka_raw = get(raw, "alsoKnownAs", nothing)
    if aka_raw isa AbstractVector
        for item in aka_raw
            item isa AbstractString && push!(aka, String(item))
        end
    end

    vms = DIDVerificationMethod[]
    vm_raw = get(raw, "verificationMethod", nothing)
    if vm_raw isa AbstractVector
        for item in vm_raw
            item isa AbstractDict || continue
            vid = get(item, "id", nothing)
            vtype = get(item, "type", nothing)
            vctrl = get(item, "controller", nothing)
            vpk = get(item, "publicKeyMultibase", nothing)
            (vid isa AbstractString && vtype isa AbstractString && vctrl isa AbstractString) || continue
            push!(vms, DIDVerificationMethod(
                String(vid),
                String(vtype),
                String(vctrl),
                vpk isa AbstractString ? String(vpk) : nothing,
            ))
        end
    end

    svcs = DIDService[]
    svc_raw = get(raw, "service", nothing)
    if svc_raw isa AbstractVector
        for item in svc_raw
            item isa AbstractDict || continue
            sid = get(item, "id", nothing)
            stype = get(item, "type", nothing)
            sep = get(item, "serviceEndpoint", nothing)
            (sid isa AbstractString && stype isa AbstractString && sep isa AbstractString) || continue
            push!(svcs, DIDService(String(sid), String(stype), String(sep)))
        end
    end

    return DIDDocument(did, aka, vms, svcs, raw)
end

function parse_did_document(json_str::AbstractString)
    parsed = try
        JSON.parse(String(json_str), Dict{String, Any})
    catch e
        throw(IdentityError("<json>", "Invalid DID document JSON: $(sprint(showerror, e))"))
    end
    return parse_did_document(parsed)
end

function _is_http_url(s::AbstractString)
    return startswith(s, "https://") || startswith(s, "http://")
end

"""
    pds_endpoint(doc::DIDDocument) -> Union{String, Nothing}

Return the `#atproto_pds` (`AtprotoPersonalDataServer`) HTTP(S) service endpoint
URL from `doc` with any trailing slash stripped, or `nothing` if absent.
"""
function pds_endpoint(doc::DIDDocument)
    full_id = string(doc.id, "#atproto_pds")
    for svc in doc.service
        if (svc.id == "#atproto_pds" || svc.id == full_id) &&
           svc.type == "AtprotoPersonalDataServer" &&
           _is_http_url(svc.serviceEndpoint)
            return String(rstrip(svc.serviceEndpoint, '/'))
        end
    end
    return nothing
end

"""
    atproto_handle(doc::DIDDocument) -> Union{Handle, Nothing}

Return the first valid `at://<handle>` claim from `doc.alsoKnownAs`, or `nothing`
if none is present. Note: handle claims are unverified until confirmed via
[`verify_handle`](@ref) or [`resolve_identity`](@ref).
"""
function atproto_handle(doc::DIDDocument)
    for entry in doc.alsoKnownAs
        startswith(entry, "at://") || continue
        cand = SubString(entry, 6)
        h = tryparse(Handle, cand)
        isnothing(h) || return h
    end
    return nothing
end

"""
    signing_key(doc::DIDDocument) -> Union{DIDVerificationMethod, Nothing}

Return the `#atproto` repository signing [`DIDVerificationMethod`](@ref) from `doc`,
or `nothing` if absent.
"""
function signing_key(doc::DIDDocument)
    full_id = string(doc.id, "#atproto")
    for vm in doc.verificationMethod
        if vm.id == "#atproto" || vm.id == full_id
            return vm
        end
    end
    return nothing
end
