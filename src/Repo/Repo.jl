module Repo

using ..Crypto
using ..DagCbor
using ..Syntax
using ..Lexicon
using ..Crypto: sign_digest, verify_did_sig

export ATProtoRepoError,
    MissingBlockError,
    AbstractBlockStore,
    MemoryBlockStore,
    BlockMap,
    put_block!,
    put_blocks!,
    get_block,
    has_block,
    read_obj,
    Leaf,
    MST,
    leading_zeros_on_hash,
    is_valid_mst_key,
    ensure_valid_mst_key,
    mst_pointer,
    mst_create,
    mst_load,
    mst_add,
    mst_get,
    mst_update,
    mst_delete,
    mst_leaves,
    mst_list,
    mst_leaf_count,
    mst_get_layer!,
    mst_all_cids,
    mst_get_unstored_blocks,
    mst_cids_for_path,
    mst_equals,
    DataDiff,
    mst_diff,
    CarReader,

    read_car,
    write_car,
    write_car_v2,
    _car_payload,
    car_blocks,
    create_commit,
    load_commit,
    verify_commit_sig,
    verify_commit_chain

include("storage.jl")
include("mst_util.jl")
include("mst.jl")
include("diff.jl")
include("car.jl")
include("commit.jl")

end # module
