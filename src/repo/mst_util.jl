# MST utilities. Port of `packages/repo/src/mst/util.ts` + `indigo/mst/mst_util.go`.

const MST_KEY_REGEX = r"^[a-zA-Z0-9_~\-:.]*$"

"""
    leading_zeros_on_hash(key) -> Int

MST layer computation: the number of leading zero *bits* in the SHA-256 of
the key (two bits per byte tier, ~4-way fanout).
"""
function leading_zeros_on_hash(key::Union{AbstractString,AbstractVector{UInt8}})::Int
    hash = sha256(key)
    leading_zeros = 0
    for byte in hash
        byte < 64 && (leading_zeros += 1)
        byte < 16 && (leading_zeros += 1)
        byte < 4 && (leading_zeros += 1)
        if byte == 0
            leading_zeros += 1
        else
            break
        end
    end
    return leading_zeros
end

"The layer of a node: the leading zeros of its first leaf's key."
function layer_for_entries(entries)::Union{Int,Nothing}
    for entry in entries
        entry isa Leaf && return leading_zeros_on_hash(entry.key)
    end
    return nothing
end

"""
    is_valid_mst_key(key) -> Bool

MST keys are `<collection>/<record-key>` (both parts non-empty, allowed
chars only, total ≤1024 chars).
"""
function is_valid_mst_key(key::AbstractString)::Bool
    length(key) <= 1024 || return false
    parts = split(key, '/')
    length(parts) == 2 || return false
    return !isempty(parts[1]) && !isempty(parts[2]) &&
           occursin(MST_KEY_REGEX, parts[1]) && occursin(MST_KEY_REGEX, parts[2])
end

function ensure_valid_mst_key(key::AbstractString)
    is_valid_mst_key(key) ||
        throw(ArgumentError("Not a valid MST key: $key"))
    return key
end

"Length of the common prefix between two strings (by codeunit; valid MST
keys are ASCII, so codeunit and character positions coincide)."
function count_prefix_len(a::AbstractString, b::AbstractString)::Int
    i = 0
    while i < min(ncodeunits(a), ncodeunits(b))
        codeunit(a, i + 1) == codeunit(b, i + 1) || break
        i += 1
    end
    return i
end

# --- node data (de)serialization ------------------------------------------------
#
# CBOR node form (per the MST spec):
#   { l: subtree-or-null, e: [{p, k: <bytes>, v: CID, t: subtree-or-null}] }
# where p is the shared-prefix length with the previous key and k is the
# remaining suffix as ASCII bytes.

serialize_leaf_key(key::AbstractString) = DagBytes(copy(codeunits(key)))

function serialize_node_data(entries::AbstractVector)
    data = Dict{String,Any}("l" => nothing, "e" => Any[])
    i = 1
    if !isempty(entries) && entries[1] isa MST
        i = 2
        data["l"] = mst_pointer(entries[1])
    end
    last_key = ""
    while i <= length(entries)
        leaf = entries[i]
        leaf isa MST &&
            throw(ArgumentError("Not a valid node: two subtrees next to each other"))
        i += 1
        subtree = nothing
        if i <= length(entries) && entries[i] isa MST
            subtree = mst_pointer(entries[i])
            i += 1
        end
        ensure_valid_mst_key(leaf.key)
        prefix_len = count_prefix_len(last_key, leaf.key)
        push!(data["e"], Dict{String,Any}(
            "p" => prefix_len,
            "k" => serialize_leaf_key(leaf.key[(prefix_len + 1):end]),
            "v" => leaf.value,
            "t" => subtree,
        ))
        last_key = leaf.key
    end
    return data
end

function deserialize_node_data(storage::AbstractBlockStore, data::AbstractDict;
                               layer::Union{Int,Nothing} = nothing)
    entries = Vector{Any}()
    l = get(data, "l", nothing)
    if l !== nothing
        push!(entries, mst_load(storage, l; layer = layer === nothing ? nothing : layer - 1))
    end
    last_key = ""
    for entry in data["e"]
        suffix = entry["k"] isa DagBytes ? entry["k"].bytes : entry["k"]
        # valid MST keys are ASCII, so char and byte prefixes coincide
        prefix = first(last_key, Int(entry["p"]))
        key = string(prefix, String(suffix))
        ensure_valid_mst_key(key)
        push!(entries, Leaf(key, entry["v"]))
        t = get(entry, "t", nothing)
        if t !== nothing
            push!(entries, mst_load(storage, t; layer = layer === nothing ? nothing : layer - 1))
        end
        last_key = key
    end
    return entries
end

function cid_for_entries(entries::AbstractVector)::CID
    bytes = dag_cbor_encode(serialize_node_data(entries))
    return cid_for_dagcbor(bytes)
end
