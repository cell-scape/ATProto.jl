# Merkle Search Tree. Port of `packages/repo/src/mst/mst.ts` (which follows
# https://hal.inria.fr/hal-02303490/document):
#
#   - an ordered, deterministic, insert-order-independent tree
#   - a key's layer = leading zero bits of SHA-256(key) (~4-way fanout)
#   - each subtree is addressed by its content CID
#   - nodes are CBOR with prefix-compressed keys; never two neighboring subtrees
#
# Mutation returns new MSTs sharing unchanged structure (immutable style);
# subtree entries load lazily from the block store.

"""
    Leaf

An MST leaf: `key` (an MST key `"<collection>/<rkey>"`) and the record's CID.
"""
struct Leaf
    key::String
    value::CID
end

Base.:(==)(a::Leaf, b::Leaf) = a.key == b.key && a.value == b.value

"""
    MST

A Merkle Search Tree node. `entries === nothing` means the node is lazy
(loads from `pointer` on first access). Construct via [`mst_create`](@ref) /
[`mst_load`](@ref); mutate via [`mst_add`](@ref), [`mst_update`](@ref),
[`mst_delete`](@ref).
"""
mutable struct MST
    storage::AbstractBlockStore
    pointer::CID
    outdated_pointer::Bool
    entries::Union{Nothing,Vector{Any}}
    layer::Union{Nothing,Int}
end

"Create an MST node from entries (computing its CID)."
function mst_create(storage::AbstractBlockStore, entries::AbstractVector = Any[];
                    layer::Union{Int,Nothing} = nothing)
    pointer = cid_for_entries(entries)
    return MST(storage, pointer, false, isempty(entries) ? Any[entries...] : Any[entries...], layer)
end

"Load an MST node lazily by CID (entries read on demand)."
mst_load(storage::AbstractBlockStore, cid::CID;
         layer::Union{Int,Nothing} = nothing) =
    MST(storage, cid, false, nothing, layer)

# --- getters (lazy load) ----------------------------------------------------------

"Materialize entries, loading from storage once."
function mst_get_entries!(mst::MST)::Vector{Any}
    if mst.entries !== nothing
        cached = mst.entries
        return cached::Vector{Any}
    end
    data = read_obj(mst.storage, mst.pointer)
    # layer of this node from its first leaf's key
    first_leaf = get(data, "e", nothing)
    layer = if first_leaf isa AbstractVector && !isempty(first_leaf)
        k = first_leaf[1]["k"]
        bytes = k isa DagBytes ? k.bytes : collect(k)
        leading_zeros_on_hash(bytes)
    else
        nothing
    end
    loaded = deserialize_node_data(mst.storage, data; layer)::Vector{Any}
    mst.entries = loaded
    return loaded
end

"A new node with the same storage/layer; pointer recomputed lazily."
function _newtree(mst::MST, entries::AbstractVector)::MST
    return MST(mst.storage, mst.pointer, true, Any[entries...], mst.layer)
end

"The node's CID (recomputed if outdated)."
function mst_pointer(mst::MST)::CID
    mst.outdated_pointer || return mst.pointer
    (cid, _) = mst_serialize(mst)
    mst.pointer = cid
    mst.outdated_pointer = false
    return cid
end

"Serialize this node to (cid, bytes), ensuring subtree pointers are current."
function mst_serialize(mst::MST)
    entries = mst_get_entries!(mst)
    for e in entries
        e isa MST && e.outdated_pointer && mst_pointer(e)
    end
    entries = mst_get_entries!(mst)
    data = serialize_node_data(entries)
    bytes = dag_cbor_encode(data)
    return (cid = cid_for_dagcbor(bytes), bytes = bytes)
end

"The layer of this node (defaulting to 0 for empty trees)."
function mst_get_layer!(mst::MST)::Int
    layer = _attempt_get_layer!(mst)
    local result::Int
    if layer === nothing
        result = 0
    else
        result = layer
    end
    mst.layer = result
    return result
end

function _attempt_get_layer!(mst::MST)::Union{Int,Nothing}
    mst.layer !== nothing && return mst.layer
    entries = mst_get_entries!(mst)
    layer = layer_for_entries(entries)
    if layer === nothing
        for entry in entries
            if entry isa MST
                child = _attempt_get_layer!(entry)
                if child !== nothing
                    layer = child + 1
                    break
                end
            end
        end
    end
    layer !== nothing && (mst.layer = layer)
    return layer
end

# --- entry helpers ------------------------------------------------------------------

function _at_index(mst::MST, i::Int)
    entries = mst_get_entries!(mst)
    (1 <= i <= length(entries)) || return nothing
    return entries[i]
end

_at_index(mst::MST, ::Nothing) = nothing

"index of the first leaf with key >= query, or length+1"
function _find_gt_or_equal_leaf_index(mst::MST, key::AbstractString)::Int
    entries = mst_get_entries!(mst)
    for (i, entry) in enumerate(entries)
        entry isa Leaf && entry.key >= key && return i
    end
    return length(entries) + 1
end

_update_entry(mst::MST, index::Int, entry) =
    _newtree(mst, vcat(mst_get_entries!(mst)[1:index-1], Any[entry],
                       mst_get_entries!(mst)[index+1:end]))
_remove_entry(mst::MST, index::Int) =
    _newtree(mst, vcat(mst_get_entries!(mst)[1:index-1],
                       mst_get_entries!(mst)[index+1:end]))
_append(mst::MST, entry) = _newtree(mst, vcat(mst_get_entries!(mst), Any[entry]))
_prepend(mst::MST, entry) = _newtree(mst, vcat(Any[entry], mst_get_entries!(mst)))
_splice_in(mst::MST, entry, index::Int) =
    _newtree(mst, vcat(mst_get_entries!(mst)[1:index-1], Any[entry],
                       mst_get_entries!(mst)[index:end]))

function _replace_with_split(mst::MST, index::Int, left, leaf::Leaf, right)
    updated = vcat(mst_get_entries!(mst)[1:index-1],
                   left === nothing ? Any[] : Any[left],
                   Any[leaf],
                   right === nothing ? Any[] : Any[right],
                   mst_get_entries!(mst)[index+1:end])
    return _newtree(mst, updated)
end

# --- core operations --------------------------------------------------------------

"""
    mst_add(mst, key, value; known_zeros=nothing) -> MST

Add a leaf; throws if the key exists. `known_zeros` may pre-supply the key's
layer for performance.
"""
function mst_add(mst::MST, key::AbstractString, value::CID;
                 known_zeros::Union{Int,Nothing} = nothing)::MST
    ensure_valid_mst_key(key)
    key_zeros = known_zeros === nothing ? leading_zeros_on_hash(key) : known_zeros
    layer = mst_get_layer!(mst)
    new_leaf = Leaf(key, value)
    if key_zeros == layer
        # belongs in this layer
        index = _find_gt_or_equal_leaf_index(mst, key)
        found = _at_index(mst, index)
        if found isa Leaf && found.key == key
            throw(ArgumentError("There is already a value at key: $key"))
        end
        prev_node = _at_index(mst, index - 1)
        if prev_node === nothing || prev_node isa Leaf
            return _splice_in(mst, new_leaf, index)
        else
            (split_left, split_right) = _split_around(prev_node, key)
            return _replace_with_split(mst, index - 1, split_left, new_leaf, split_right)
        end
    elseif key_zeros < layer
        # belongs on a lower layer
        index = _find_gt_or_equal_leaf_index(mst, key)
        prev_node = _at_index(mst, index - 1)
        if prev_node isa MST
            new_subtree = mst_add(prev_node, key, value; known_zeros = key_zeros)
            return _update_entry(mst, index - 1, new_subtree)
        else
            subtree = _create_child(mst)
            new_subtree = mst_add(subtree, key, value; known_zeros = key_zeros)
            return _splice_in(mst, new_subtree, index)
        end
    else
        # belongs on a higher layer: push the tree down, adding structural nodes
        (left, right) = _split_around(mst, key)
        layer = mst_get_layer!(mst)
        extra_layers = key_zeros - layer
        for _ in 1:(extra_layers - 1)
            left = left === nothing ? nothing : _create_parent(left)
            right = right === nothing ? nothing : _create_parent(right)
        end
        updated = Any[]
        left === nothing || push!(updated, left)
        push!(updated, new_leaf)
        right === nothing || push!(updated, right)
        new_root = MST(mst.storage, mst.pointer, true, updated, key_zeros)
        return new_root
    end
end

"""
    mst_get(mst, key) -> Union{CID, Nothing}

Look up the record CID at an MST key.
"""
function mst_get(mst::MST, key::AbstractString)::Union{CID,Nothing}
    index = _find_gt_or_equal_leaf_index(mst, key)
    found = _at_index(mst, index)
    if found isa Leaf && found.key == key
        return found.value
    end
    prev = _at_index(mst, index - 1)
    if prev isa MST
        return mst_get(prev, key)
    end
    return nothing
end

"""
    mst_update(mst, key, value) -> MST

Change the value at an existing key; throws when the key is absent.
"""
function mst_update(mst::MST, key::AbstractString, value::CID)::MST
    ensure_valid_mst_key(key)
    index = _find_gt_or_equal_leaf_index(mst, key)
    found = _at_index(mst, index)
    if found isa Leaf && found.key == key
        return _update_entry(mst, index, Leaf(key, value))
    end
    prev = _at_index(mst, index - 1)
    if prev isa MST
        return _update_entry(mst, index - 1, mst_update(prev, key, value))
    end
    throw(ArgumentError("Could not find a record with key: $key"))
end

"""
    mst_delete(mst, key) -> MST

Remove a key; throws when absent. Trims any chain of single-child structural
nodes above.
"""
function mst_delete(mst::MST, key::AbstractString)::MST
    return mst_trim_top(_delete_recurse(mst, key))
end

function _delete_recurse(mst::MST, key::AbstractString)::MST
    index = _find_gt_or_equal_leaf_index(mst, key)
    found = _at_index(mst, index)
    if found isa Leaf && found.key == key
        prev = _at_index(mst, index - 1)
        next = _at_index(mst, index + 1)
        if prev isa MST && next isa MST
            merged = _append_merge(prev, next)
            entries = mst_get_entries!(mst)
            return _newtree(mst, vcat(entries[1:index-2], Any[merged], entries[index+2:end]))
        else
            return _remove_entry(mst, index)
        end
    end
    prev = _at_index(mst, index - 1)
    if prev isa MST
        subtree = _delete_recurse(prev, key)
        sub_entries = mst_get_entries!(subtree)
        if isempty(sub_entries)
            return _remove_entry(mst, index - 1)
        else
            return _update_entry(mst, index - 1, subtree)
        end
    end
    throw(ArgumentError("Could not find a record with key: $key"))
end

"If the top node only points to a subtree, return that subtree (recursively)."
function mst_trim_top(mst::MST)::MST
    entries = try
        mst_get_entries!(mst)
    catch err
        err isa MissingBlockError && return mst
        rethrow()
    end
    if length(entries) == 1 && entries[1] isa MST
        return mst_trim_top(entries[1])
    end
    return mst
end

# --- splits & merges -----------------------------------------------------------------

"Recursively split a subtree around a key into (left, right)."
function _split_around(mst::MST, key::AbstractString)
    index = _find_gt_or_equal_leaf_index(mst, key)
    entries = mst_get_entries!(mst)
    left_entries = entries[1:index-1]
    right_entries = entries[index:end]
    left = _newtree(mst, left_entries)
    right = _newtree(mst, right_entries)

    # if the far right of the left side is a subtree, split it too
    last_in_left = isempty(left_entries) ? nothing : left_entries[end]
    if last_in_left isa MST
        left = _remove_entry(left, length(left_entries))
        (sl, sr) = _split_around(last_in_left, key)
        sl === nothing || (left = _append(left, sl))
        sr === nothing || (right = _prepend(right, sr))
    end

    left = isempty(mst_get_entries!(left)) ? nothing : left
    right = isempty(mst_get_entries!(right)) ? nothing : right
    return (left, right)
end

"Merge two same-layer trees where all right keys exceed all left keys."
function _append_merge(left::MST, right::MST)::MST
    mst_get_layer!(left) == mst_get_layer!(right) ||
        throw(ArgumentError("Trying to merge two nodes from different layers of the MST"))
    left_entries = mst_get_entries!(left)
    right_entries = mst_get_entries!(right)
    last_in_left = left_entries[end]
    first_in_right = right_entries[1]
    if last_in_left isa MST && first_in_right isa MST
        merged = _append_merge(last_in_left, first_in_right)
        return _newtree(left,
            vcat(left_entries[1:end-1], Any[merged], right_entries[2:end]))
    end
    return _newtree(left, vcat(left_entries, right_entries))
end

_create_child(mst::MST) = mst_create(mst.storage, Any[]; layer = mst_get_layer!(mst) - 1)

function _create_parent(mst::MST)::MST
    layer = mst_get_layer!(mst)
    parent = MST(mst.storage, mst.pointer, true, Any[mst], layer + 1)
    return parent
end

# --- traversal ------------------------------------------------------------------

"Depth-first walk of all nodes and leaves (in key order)."
function mst_walk(mst::MST)
    Channel() do ch
        _walk!(ch, mst)
    end
end

function _walk!(ch, mst::MST)
    put!(ch, mst)
    for entry in mst_get_entries!(mst)
        if entry isa MST
            _walk!(ch, entry)
        else
            put!(ch, entry)
        end
    end
    return nothing
end

"All leaves in key order."
mst_leaves(mst::MST) = Leaf[e for e in mst_walk(mst) if e isa Leaf]

"List `count` leaves after `after` and before `before`."
function mst_list(mst::MST, count::Int = typemax(Int);
                  after::Union{AbstractString,Nothing} = nothing,
                  before::Union{AbstractString,Nothing} = nothing)
    vals = Leaf[]
    for leaf in mst_leaves(mst)
        after !== nothing && leaf.key <= after && continue
        before !== nothing && leaf.key >= before && break
        length(vals) >= count && break
        push!(vals, leaf)
    end
    return vals
end

mst_leaf_count(mst::MST) = length(mst_leaves(mst))

"All CIDs in the tree: every node pointer and every leaf value."
function mst_all_cids(mst::MST)
    cids = Set{CID}()
    push!(cids, mst_pointer(mst))
    for entry in mst_get_entries!(mst)
        if entry isa Leaf
            push!(cids, entry.value)
        else
            union!(cids, mst_all_cids(entry))
        end
    end
    return cids
end

"Blocks needed to persist this (changed) subtree: node + unstored subtrees."
function mst_get_unstored_blocks(mst::MST)
    blocks = BlockMap()
    pointer = mst_pointer(mst)
    has_block(mst.storage, pointer) && return (root = pointer, blocks = blocks)
    (cid, bytes) = mst_serialize(mst)
    put_block!(blocks, cid, bytes)
    for entry in mst_get_entries!(mst)
        if entry isa MST
            sub = mst_get_unstored_blocks(entry)
            put_blocks!(blocks, sub.blocks)
        end
    end
    return (root = pointer, blocks = blocks)
end

"CIDs along the path to a key: node pointers down to the leaf value."
function mst_cids_for_path(mst::MST, key::AbstractString)::Vector{CID}
    cids = CID[mst_pointer(mst)]
    index = _find_gt_or_equal_leaf_index(mst, key)
    found = _at_index(mst, index)
    if found isa Leaf && found.key == key
        return vcat(cids, CID[found.value])
    end
    prev = _at_index(mst, index - 1)
    if prev isa MST
        return vcat(cids, mst_cids_for_path(prev, key))
    end
    return cids
end

mst_equals(a::MST, b::MST) = mst_pointer(a) == mst_pointer(b)
mst_equals(a::Leaf, b::Leaf) = a == b
mst_equals(a::MST, ::Leaf) = false
mst_equals(::Leaf, b::MST) = false
