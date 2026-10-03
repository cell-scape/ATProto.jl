using Test
using ATProto
using ATProto.Repo
using ATProto.Crypto
using ATProto.DagCbor

@testset "CAR v1 round trip" begin
    store = MemoryBlockStore()
    tree = mst_create(store)
    for i in 1:10
        tree = mst_add(tree, "com.example.record/k$i", cid_for_dagcbor("record $i"))
    end
    unstored = mst_get_unstored_blocks(tree)
    put_blocks!(store, unstored.blocks)

    # write all blocks (MST nodes + record values)
    all_blocks = BlockMap()
    put_blocks!(all_blocks, unstored.blocks)
    for i in 1:10
        put_block!(all_blocks, cid_for_dagcbor("record $i"),
                   dag_cbor_encode(Dict{String,Any}("n" => i)))
    end
    car = write_car(CID[mst_pointer(tree)], all_blocks)

    (roots, blocks) = read_car(car)
    @test length(roots) == 1 && roots[1] == mst_pointer(tree)
    @test length(blocks) == length(all_blocks)
    for (cid, bytes) in all_blocks
        got = blocks[cid]
        @test got[1] == cid
        @test got[2] == bytes
    end

    # reload the MST from the CAR contents
    car_store = MemoryBlockStore()
    put_blocks!(car_store, blocks)
    reloaded = mst_load(car_store, roots[1])
    @test mst_leaf_count(reloaded) == 10
    @test mst_pointer(reloaded) == mst_pointer(tree)
end

@testset "CAR v2 read" begin
    blocks = BlockMap()
    put_block!(blocks, cid_for_dagcbor("v2 test"), dag_cbor_encode(Dict("x" => 1)))
    root = first([cid for (cid, _) in blocks])
    v2 = write_car_v2(CID[root], blocks)

    # v2 prefix
    @test v2[1:6] == UInt8[0x0a, 0xa1, 0x67, 0x76, 0x32, 0x64]
    (roots, got) = read_car(v2)
    @test roots == CID[root]
    @test length(got) == 1
    for (cid, bytes) in blocks
        @test got[cid][2] == bytes
    end

    # empty CAR
    (empty_roots, empty_blocks) = read_car(write_car(CID[], BlockMap()))
    @test isempty(empty_roots) && isempty(empty_blocks)
end

@testset "CarReader iteration" begin
    blocks = BlockMap()
    for i in 1:5
        put_block!(blocks, cid_for_dagcbor("block$i"), dag_cbor_encode(Dict("i" => i)))
    end
    car = write_car(CID[], blocks)
    count = 0
    cids = Set{CID}()
    for (cid, bytes) in CarReader(_car_payload(car))
        count += 1
        push!(cids, cid)
        @test bytes == blocks[cid][2]
    end
    @test count == 5
    @test cids == Set(cid for (cid, _) in blocks)
end

@testset "commit create/load/verify" begin
    key = generate_key(Secp256k1Key)
    did_key_str = did_key(key)
    did = "did:plc:ewvi7nx4oun5hl7s6yqkgcto"

    store = MemoryBlockStore()
    tree = mst_create(store)
    for i in 1:5
        tree = mst_add(tree, "com.example.record/r$i", cid_for_dagcbor("rec$i"))
    end
    unstored = mst_get_unstored_blocks(tree)
    put_blocks!(store, unstored.blocks)

    rev = string(TID())
    (commit_cid, commit_bytes) = create_commit(store, unstored.root, did, rev;
                                               signing_key = key)
    put_block!(store, commit_cid, commit_bytes)

    # load & verify
    commit = load_commit(store, commit_cid)
    @test commit["did"] == did
    @test commit["version"] == 3
    @test commit["data"] == unstored.root
    @test commit["rev"] == rev
    @test commit["prev"] === nothing
    @test verify_commit_sig(commit; signing_key_did = did_key_str)

    # tampered commit fails verification
    tampered = Dict{String,Any}(commit)
    tampered["rev"] = string(TID())
    @test !verify_commit_sig(tampered; signing_key_did = did_key_str)
    # wrong key fails
    other_key = generate_key(Secp256k1Key)
    @test !verify_commit_sig(commit; signing_key_did = did_key(other_key))

    # chain: commit2 with prev=commit1
    tree2 = mst_add(tree, "com.example.record/r6", cid_for_dagcbor("rec6"))
    unstored2 = mst_get_unstored_blocks(tree2)
    put_blocks!(store, unstored2.blocks)
    rev2 = string(TID())
    (cid2, bytes2) = create_commit(store, unstored2.root, did, rev2;
                                   prev = commit_cid, signing_key = key)
    put_block!(store, cid2, bytes2)

    chain = verify_commit_chain(store, cid2, did_key_str)
    @test length(chain) == 2
    @test chain[1] == cid2
    @test chain[2] == commit_cid
    @test verify_commit_chain(store, cid2, did_key_str; verify_all = false) == CID[cid2]
end

@testset "CAR with commit round trip" begin
    key = generate_key(Secp256k1Key)
    store = MemoryBlockStore()
    tree = mst_create(store)
    for i in 1:3
        tree = mst_add(tree, "com.example.record/x$i", cid_for_dagcbor("x$i"))
    end
    unstored = mst_get_unstored_blocks(tree)
    put_blocks!(store, unstored.blocks)
    (commit_cid, commit_bytes) = create_commit(store, unstored.root,
                                               "did:plc:abc", string(TID());
                                               signing_key = key)

    # export everything to a CAR
    export_blocks = BlockMap()
    put_blocks!(export_blocks, unstored.blocks)
    put_block!(export_blocks, cid_for_dagcbor("x1"), dag_cbor_encode(Dict("i" => 1)))
    put_block!(export_blocks, cid_for_dagcbor("x2"), dag_cbor_encode(Dict("i" => 2)))
    put_block!(export_blocks, cid_for_dagcbor("x3"), dag_cbor_encode(Dict("i" => 3)))
    put_block!(export_blocks, commit_cid, commit_bytes)
    car = write_car(CID[commit_cid], export_blocks)

    # import and verify the full repo state from the CAR
    (roots, blocks) = read_car(car)
    import_store = MemoryBlockStore()
    put_blocks!(import_store, blocks)
    @test verify_commit_chain(import_store, roots[1], did_key(key)) == CID[commit_cid]
    commit = load_commit(import_store, roots[1])
    imported_tree = mst_load(import_store, commit["data"])
    @test mst_leaf_count(imported_tree) == 3
    @test mst_pointer(imported_tree) == unstored.root
end
