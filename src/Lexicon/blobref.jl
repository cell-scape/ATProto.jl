# Blob references. Port of `packages/lexicon/src/blob-refs.ts`.
#
# Two JSON forms exist:
#   - typed (modern):   {"\$type": "blob", "ref": {"\$link": "<cid>"}, "mimeType", "size"}
#   - untyped (legacy): {"cid": "<cid-string>", "mimeType"}
# The IPLD (DAG-CBOR) form uses an empty-string key for the CID link:
#   {"" => CID, "mimeType" => ..., "size" => ...}

"""
    BlobRef

A blob reference: the CID of an uploaded blob, its MIME type, and size in
bytes. `original` retains the JSON form the ref was parsed from.
"""
struct BlobRef
    ref::CID
    mime_type::String
    size::Int
    original::Dict{String,Any}
end

BlobRef(ref::CID, mime_type::AbstractString, size::Integer) =
    BlobRef(ref, String(mime_type), Int(size),
            Dict{String,Any}("\$type" => "blob",
                             "ref" => Dict{String,Any}("\$link" => string(ref)),
                             "mimeType" => String(mime_type),
                             "size" => Int(size)))

"""
    blob_ref_from_json(obj) -> Union{BlobRef, Nothing}

Parse a JSON blob ref (typed or legacy form). `nothing` when `obj` is not a
blob ref. Accepts `ref` as a `{"\$link"}` marker dict, a `CID`, or a CID
string.
"""
function blob_ref_from_json(obj)::Union{BlobRef,Nothing}
    obj isa AbstractDict || return nothing
    if get(obj, "\$type", nothing) == "blob" && haskey(obj, "mimeType")
        ref = get(obj, "ref", nothing)
        cid = if ref isa CID
            ref
        elseif ref isa AbstractDict && haskey(ref, "\$link")
            try
                cid_parse(String(ref["\$link"]))
            catch
                return nothing
            end
        elseif ref isa AbstractString
            try
                cid_parse(String(ref))
            catch
                return nothing
            end
        else
            return nothing
        end
        size = get(obj, "size", nothing)
        return BlobRef(cid, String(obj["mimeType"]),
                       size isa Integer ? Int(size) : -1, Dict{String,Any}(obj))
    elseif haskey(obj, "cid") && haskey(obj, "mimeType")
        cid = try
            cid_parse(String(obj["cid"]))
        catch
            return nothing
        end
        return BlobRef(cid, String(obj["mimeType"]), -1, Dict{String,Any}(obj))
    end
    return nothing
end

"The typed JSON form (with `\$link` markers), suitable for serialize_lex."
function blob_ref_to_json(br::BlobRef)::Dict{String,Any}
    return Dict{String,Any}(
        "\$type" => "blob",
        "ref" => Dict{String,Any}("\$link" => string(br.ref)),
        "mimeType" => br.mime_type,
        "size" => br.size,
    )
end

"""
    blob_ref_from_ipld(obj) -> Union{BlobRef, Nothing}

Parse the IPLD (DAG-CBOR) form: `{"" => CID, "mimeType" => ..., "size" => ...}`.
"""
function blob_ref_from_ipld(obj)::Union{BlobRef,Nothing}
    obj isa AbstractDict || return nothing
    cid = get(obj, "", nothing)
    cid isa CID || return nothing
    mime = get(obj, "mimeType", nothing)
    mime isa AbstractString || return nothing
    size = get(obj, "size", nothing)
    return BlobRef(cid, String(mime), size isa Integer ? Int(size) : -1,
                   Dict{String,Any}(obj))
end

"The IPLD (DAG-CBOR) form with the empty-string CID key."
function blob_ref_to_ipld(br::BlobRef)::Dict{String,Any}
    return Dict{String,Any}(
        "" => br.ref,
        "mimeType" => br.mime_type,
        "size" => br.size,
    )
end

Base.:(==)(a::BlobRef, b::BlobRef) =
    a.ref == b.ref && a.mime_type == b.mime_type && a.size == b.size
Base.hash(br::BlobRef, h::UInt) = hash((br.ref, br.mime_type, br.size), h)
Base.show(io::IO, br::BlobRef) =
    print(io, "BlobRef(", string(br.ref), ", ", br.mime_type, ", ", br.size, ")")
