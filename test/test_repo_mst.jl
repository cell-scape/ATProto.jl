using Test
using ATProto
using ATProto.Repo
using ATProto.Crypto

const CID1 = "bafyreie5cvv4h45feadgeuwhbcutmh6t2ceseocckahdoe6uat64zmz454"

function cid1()
    return cid_parse(CID1)
end

"Build an MST from a key=>cid map (insertion-order independent)."
function map_to_mst(store::AbstractBlockStore, m::Dict{String,Any})
    tree = mst_create(store)
    for key in sort(collect(keys(m)))
        tree = mst_add(tree, key, m[key])
    end
    return tree
end

@testset "MST layer computation" begin
    @test leading_zeros_on_hash("") == 0
    @test leading_zeros_on_hash("asdf") == 0
    @test leading_zeros_on_hash("blue") == 1
    @test leading_zeros_on_hash("2653ae71") == 0
    @test leading_zeros_on_hash("88bfafc7") == 2
    @test leading_zeros_on_hash("2a92d355") == 4
    @test leading_zeros_on_hash("884976f5") == 6
    @test leading_zeros_on_hash("app.bsky.feed.post/454397e440ec") == 4
    @test leading_zeros_on_hash("app.bsky.feed.post/9adeb165882c") == 8
end

@testset "MST key validation" begin
    @test is_valid_mst_key("com.example.record/3jzfcijpj2z2a")
    @test is_valid_mst_key("a.b/_~:-.1")
    @test !is_valid_mst_key("nocolon")
    @test !is_valid_mst_key("a/b/c")
    @test !is_valid_mst_key("/rkey")
    @test !is_valid_mst_key("coll/")
    @test !is_valid_mst_key("col l/rkey")
    @test_throws ArgumentError ensure_valid_mst_key("bad")
end

@testset "MST interop: known root CIDs" begin
    # vectors from indigo/mst_interop_test.go (matching the TS implementation)

    # empty tree
    store = MemoryBlockStore()
    @test string(mst_pointer(map_to_mst(store, Dict{String,Any}()))) ==
          "bafyreie5737gdxlw5i64vzichcalba3z2v5n6icifvx5xytvske7mr3hpm"

    # no depth, single entry
    store = MemoryBlockStore()
    @test string(mst_pointer(map_to_mst(store, Dict{String,Any}(
        "com.example.record/3jqfcqzm3fo2j" => cid1())))) ==
          "bafyreibj4lsc3aqnrvphp5xmrnfoorvru4wynt6lwidqbm2623a6tatzdu"

    # single layer=2 entry
    store = MemoryBlockStore()
    @test string(mst_pointer(map_to_mst(store, Dict{String,Any}(
        "com.example.record/3jqfcqzm3fx2j" => cid1())))) ==
          "bafyreih7wfei65pxzhauoibu3ls7jgmkju4bspy4t2ha2qdjnzqvoy33ai"

    # simple, with some depth
    store = MemoryBlockStore()
    @test string(mst_pointer(map_to_mst(store, Dict{String,Any}(
        "com.example.record/3jqfcqzm3fp2j" => cid1(),
        "com.example.record/3jqfcqzm3fr2j" => cid1(),
        "com.example.record/3jqfcqzm3fs2j" => cid1(),
        "com.example.record/3jqfcqzm3ft2j" => cid1(),
        "com.example.record/3jqfcqzm4fc2j" => cid1())))) ==
          "bafyreicmahysq4n6wfuxo522m6dpiy7z7qzym3dzs756t5n7nfdgccwq7m"
end

@testset "MST interop: trim-top on delete" begin
    store = MemoryBlockStore()
    trim_map = Dict{String,Any}(
        "com.example.record/3jqfcqzm3fn2j" => cid1(),  # level 0
        "com.example.record/3jqfcqzm3fo2j" => cid1(),  # level 0
        "com.example.record/3jqfcqzm3fp2j" => cid1(),  # level 0
        "com.example.record/3jqfcqzm3fs2j" => cid1(),  # level 0
        "com.example.record/3jqfcqzm3ft2j" => cid1(),  # level 0
        "com.example.record/3jqfcqzm3fu2j" => cid1(),  # level 1
    )
    tree = map_to_mst(store, trim_map)
    @test mst_get_layer!(tree) == 1
    @test string(mst_pointer(tree)) ==
          "bafyreifnqrwbk6ffmyaz5qtujqrzf5qmxf7cbxvgzktl4e3gabuxbtatv4"

    tree = mst_delete(tree, "com.example.record/3jqfcqzm3fs2j")
    @test mst_get_layer!(tree) == 0
    @test string(mst_pointer(tree)) ==
          "bafyreie4kjuxbwkhzg2i5dljaswcroeih4dgiqq6pazcmunwt2byd725vi"
end

@testset "MST interop: insertion splits" begin
    store = MemoryBlockStore()
    insertion_map = Dict{String,Any}(
        "com.example.record/3jqfcqzm3fo2j" => cid1(),  # A; level 0
        "com.example.record/3jqfcqzm3fp2j" => cid1(),  # B; level 0
        "com.example.record/3jqfcqzm3fr2j" => cid1(),  # C; level 0
        "com.example.record/3jqfcqzm3fs2j" => cid1(),  # D; level 1
        "com.example.record/3jqfcqzm3ft2j" => cid1(),  # E; level 0
        "com.example.record/3jqfcqzm3fz2j" => cid1(),  # G; level 0
        "com.example.record/3jqfcqzm4fc2j" => cid1(),  # H; level 0
        "com.example.record/3jqfcqzm4fd2j" => cid1(),  # I; level 1
        "com.example.record/3jqfcqzm4ff2j" => cid1(),  # J; level 0
        "com.example.record/3jqfcqzm4fg2j" => cid1(),  # K; level 0
        "com.example.record/3jqfcqzm4fh2j" => cid1(),  # L; level 0
    )
    tree = map_to_mst(store, insertion_map)
    @test mst_get_layer!(tree) == 1
    @test string(mst_pointer(tree)) ==
          "bafyreiettyludka6fpgp33stwxfuwhkzlur6chs4d2v4nkmq2j3ogpdjem"

    # insert F (level 2): pushes E into a new node under D
    tree = mst_add(tree, "com.example.record/3jqfcqzm3fx2j", cid1())
    @test mst_get_layer!(tree) == 2
    @test string(mst_pointer(tree)) ==
          "bafyreid2x5eqs4w4qxvc5jiwda4cien3gw2q6cshofxwnvv7iucrmfohpm"

    # remove F: back to the original root
    tree = mst_delete(tree, "com.example.record/3jqfcqzm3fx2j")
    @test mst_get_layer!(tree) == 1
    @test string(mst_pointer(tree)) ==
          "bafyreiettyludka6fpgp33stwxfuwhkzlur6chs4d2v4nkmq2j3ogpdjem"
end

@testset "MST interop: layer jumps" begin
    store = MemoryBlockStore()
    tree = map_to_mst(store, Dict{String,Any}(
        "com.example.record/3jqfcqzm3ft2j" => cid1(),  # A; level 0
        "com.example.record/3jqfcqzm3fz2j" => cid1(),  # C; level 0
    ))
    @test mst_get_layer!(tree) == 0
    @test string(mst_pointer(tree)) ==
          "bafyreidfcktqnfmykz2ps3dbul35pepleq7kvv526g47xahuz3rqtptmky"

    # insert B (level 2)
    tree = mst_add(tree, "com.example.record/3jqfcqzm3fx2j", cid1())
    @test string(mst_pointer(tree)) ==
          "bafyreiavxaxdz7o7rbvr3zg2liox2yww46t7g6hkehx4i4h3lwudly7dhy"

    # remove B
    tree = mst_delete(tree, "com.example.record/3jqfcqzm3fx2j")
    @test string(mst_pointer(tree)) ==
          "bafyreidfcktqnfmykz2ps3dbul35pepleq7kvv526g47xahuz3rqtptmky"

    # insert B (level 2) and D (level 1)
    tree = mst_add(tree, "com.example.record/3jqfcqzm3fx2j", cid1())
    tree = mst_add(tree, "com.example.record/3jqfcqzm4fd2j", cid1())
    @test mst_get_layer!(tree) == 2
    @test string(mst_pointer(tree)) ==
          "bafyreig4jv3vuajbsybhyvb7gggvpwh2zszwfyttjrj6qwvcsp24h6popu"

    # remove D
    tree = mst_delete(tree, "com.example.record/3jqfcqzm4fd2j")
    @test mst_get_layer!(tree) == 2
    @test string(mst_pointer(tree)) ==
          "bafyreiavxaxdz7o7rbvr3zg2liox2yww46t7g6hkehx4i4h3lwudly7dhy"
end

@testset "MST CRUD + persistence" begin
    store = MemoryBlockStore()
    tree = mst_create(store)
    @test mst_leaf_count(tree) == 0

    values = [cid_for_dagcbor("value $i") for i in 1:20]
    keys = ["com.example.record/key$i" for i in 1:20]
    for (k, v) in zip(keys, values)
        tree = mst_add(tree, k, v)
    end

    # get
    for (k, v) in zip(keys, values)
        @test mst_get(tree, k) == v
    end
    @test mst_get(tree, "com.example.record/missing") === nothing

    # duplicate add throws
    @test_throws ArgumentError mst_add(tree, keys[1], values[1])

    # update changes the root but keeps other leaves
    new_value = cid_for_dagcbor("updated")
    tree2 = mst_update(tree, keys[5], new_value)
    @test mst_get(tree2, keys[5]) == new_value
    @test mst_get(tree2, keys[6]) == values[6]
    @test mst_pointer(tree) != mst_pointer(tree2)
    @test_throws ArgumentError mst_update(tree, "com.example.record/nope", new_value)

    # delete
    tree3 = mst_delete(tree2, keys[5])
    @test mst_get(tree3, keys[5]) === nothing
    @test mst_leaf_count(tree3) == 19
    @test_throws ArgumentError mst_delete(tree3, keys[5])

    # persist blocks & reload from storage by root pointer
    unstored = mst_get_unstored_blocks(tree3)
    put_blocks!(store, unstored.blocks)
    @test has_block(store, unstored.root)
    reloaded = mst_load(store, unstored.root)
    @test mst_leaf_count(reloaded) == 19
    @test mst_get(reloaded, keys[6]) == values[6]

    # leaves in key order
    leaves = mst_leaves(reloaded)
    sorted_keys = sort(keys[1:end .!= 5])
    @test [l.key for l in leaves] == sorted_keys

    # list with pagination
    page = mst_list(reloaded, 5; after = "com.example.record/key1")
    @test [l.key for l in page] == sort(keys)[2:6]

    # cids_for_path reaches the leaf value
    path = mst_cids_for_path(reloaded, keys[10])
    @test path[end] == values[10]
    @test path[1] == mst_pointer(reloaded)

    # all_cids contains every node + value
    all_cids = mst_all_cids(reloaded)
    for v in values[1:end .!= 5]
        @test v in all_cids
    end
    @test mst_pointer(reloaded) in all_cids
end

@testset "MST diff" begin
    store = MemoryBlockStore()
    a_keys = ["com.example.record/k$i" for i in 1:10]
    v(i) = cid_for_dagcbor("v$i")
    tree = mst_create(store)
    for (i, k) in enumerate(a_keys)
        tree = mst_add(tree, k, v(i))
    end

    # diff against nothing -> all adds
    d0 = mst_diff(tree)
    @test length(d0.adds) == 10
    @test isempty(d0.updates) && isempty(d0.deletes)

    # modify: update 3, delete 2, add 2
    tree2 = mst_update(tree, a_keys[2], cid_for_dagcbor("new2"))
    tree2 = mst_update(tree2, a_keys[5], cid_for_dagcbor("new5"))
    tree2 = mst_update(tree2, a_keys[7], cid_for_dagcbor("new7"))
    tree2 = mst_delete(tree2, a_keys[1])
    tree2 = mst_delete(tree2, a_keys[9])
    tree2 = mst_add(tree2, "com.example.record/zz9", cid_for_dagcbor("zz9"))
    tree2 = mst_add(tree2, "com.example.record/zz8", cid_for_dagcbor("zz8"))

    d = mst_diff(tree2, tree)
    @test sort([k for (k, _) in d.updates]) == sort([a_keys[2], a_keys[5], a_keys[7]])
    @test sort([k for (k, _) in d.deletes]) == sort([a_keys[1], a_keys[9]])
    @test sort([k for (k, _) in d.adds]) == ["com.example.record/zz8", "com.example.record/zz9"]

    # diff against self is empty
    @test isempty(mst_diff(tree2, tree2))
end
