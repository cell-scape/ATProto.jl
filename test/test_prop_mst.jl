# Property-based tests for MST invariants — the guarantees the data
# structure exists to provide.
using Test
using Supposition
using ATProto
using ATProto.Repo

using Supposition: Data

# valid rkey suffixes: alphanumeric
const rkeys = Data.map(String, Data.Text(Data.SampledFrom([Char('a'):Char('z'); Char('2'):Char('7')]);
                                         min_len = 1, max_len = 8))
const mst_keys = Data.map(k -> "com.example.record/" * k, rkeys)

const cid1 = cid_for_dagcbor("property test value")

"Build an MST by inserting keys in the given order."
function build_mst(store, keys)
    tree = mst_create(store)
    for k in keys
        tree = mst_add(tree, k, cid1)
    end
    return tree
end

@testset "property: MST determinism" begin
    # THE core MST guarantee: the root CID is independent of insertion order
    @check function insert_order_independence(keys = Data.Vectors(mst_keys;
                                                                  min_size = 1, max_size = 20))
        unique_keys = unique(keys)
        store_a = MemoryBlockStore()
        store_b = MemoryBlockStore()
        in_order = build_mst(store_a, unique_keys)
        sorted_order = build_mst(store_b, sort(unique_keys))
        mst_pointer(in_order) == mst_pointer(sorted_order)
    end

    # duplicate insertions in the stream don't matter (first wins)
    @check function duplicates_rejected_consistently(keys = Data.Vectors(mst_keys;
                                                                         min_size = 1, max_size = 8))
        unique_keys = unique(keys)
        tree = build_mst(MemoryBlockStore(), unique_keys)
        sorted_tree = build_mst(MemoryBlockStore(), sort(unique_keys))
        threw = try
            mst_add(tree, first(unique_keys), cid1)
            false  # adding a duplicate should have thrown
        catch e
            e isa ArgumentError
        end
        threw && mst_pointer(tree) == mst_pointer(sorted_tree)
    end
end

@testset "property: MST CRUD invariants" begin
    @check function get_after_add(keys = Data.Vectors(mst_keys; min_size = 1, max_size = 20))
        unique_keys = unique(keys)
        tree = build_mst(MemoryBlockStore(), unique_keys)
        all(k -> mst_get(tree, k) == cid1, unique_keys) &&
        mst_get(tree, "com.example.record/zzzzzznotthere") === nothing
    end

    @check function leaves_are_sorted(keys = Data.Vectors(mst_keys; min_size = 1, max_size = 20))
        unique_keys = unique(keys)
        tree = build_mst(MemoryBlockStore(), unique_keys)
        ks = [l.key for l in mst_leaves(tree)]
        ks == sort(ks) && Set(ks) == Set(unique_keys)
    end

    @check function update_only_changes_that_key(keys = Data.Vectors(mst_keys;
                                                                     min_size = 2, max_size = 12),
                                                 newval_bytes = Data.Vectors(Data.Integers(0x00, 0xff);
                                                                                            min_size = 1,
                                                                                            max_size = 8))
        unique_keys = unique(keys)
        length(unique_keys) >= 2 || return true
        tree = build_mst(MemoryBlockStore(), unique_keys)
        target = unique_keys[1]
        newval = cid_for_dagcbor(newval_bytes)
        tree2 = mst_update(tree, target, newval)
        mst_get(tree2, target) == newval &&
        all(k -> k == target || mst_get(tree2, k) == cid1, unique_keys)
    end
end

@testset "property: MST delete invariants" begin
    # deleting a key yields the same tree as never having added it
    @check function delete_matches_fresh_build(keys = Data.Vectors(mst_keys;
                                                                   min_size = 2, max_size = 15))
        unique_keys = unique(keys)
        length(unique_keys) >= 2 || return true
        target = unique_keys[end]  # delete the last in the generated order
        full = build_mst(MemoryBlockStore(), unique_keys)
        reduced = build_mst(MemoryBlockStore(), filter(!=(target), unique_keys))
        after_delete = mst_delete(full, target)
        mst_pointer(after_delete) == mst_pointer(reduced)
    end

    # add-then-delete returns the original root
    @check function add_delete_roundtrip(keys = Data.Vectors(mst_keys;
                                                             min_size = 1, max_size = 12),
                                         extra = rkeys)
        unique_keys = unique(keys)
        base = build_mst(MemoryBlockStore(), unique_keys)
        new_key = "com.example.record/" * extra
        new_key in unique_keys && return true
        grown = mst_add(base, new_key, cid1)
        pruned = mst_delete(grown, new_key)
        mst_pointer(pruned) == mst_pointer(base)
    end
end

@testset "property: MST diff invariants" begin
    @check function diff_self_empty(keys = Data.Vectors(mst_keys; min_size = 0, max_size = 15))
        tree = build_mst(MemoryBlockStore(), unique(keys))
        isempty(mst_diff(tree, tree))
    end

    @check function diff_counts_add_delete(keys = Data.Vectors(mst_keys;
                                                               min_size = 1, max_size = 12),
                                           extra = rkeys)
        unique_keys = unique(keys)
        new_key = "com.example.record/" * extra
        new_key in unique_keys && return true
        base = build_mst(MemoryBlockStore(), unique_keys)
        grown = mst_add(base, new_key, cid1)
        d = mst_diff(grown, base)
        length(d.adds) == 1 && isempty(d.updates) && isempty(d.deletes)
        d = mst_diff(base, grown)
        length(d.deletes) == 1 && isempty(d.updates) && isempty(d.adds)
    end
end

@testset "property: CAR round trip" begin
    @check function car_roundtrip(keys = Data.Vectors(mst_keys; min_size = 1, max_size = 12))
        unique_keys = unique(keys)
        store = MemoryBlockStore()
        tree = build_mst(store, unique_keys)
        unstored = mst_get_unstored_blocks(tree)
        put_blocks!(store, unstored.blocks)
        car = write_car(CID[mst_pointer(tree)], unstored.blocks)
        (roots, blocks) = read_car(car)
        roots == CID[mst_pointer(tree)] && length(blocks) == length(unstored.blocks)
    end
end
