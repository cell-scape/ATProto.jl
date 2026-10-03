# Block storage. Port of `packages/repo/src/{block-map,storage}`.

"""
    ATProtoRepoError <: Exception

Base error type for repository operations.
"""
abstract type ATProtoRepoError <: Exception end

"""
    MissingBlockError <: ATProtoRepoError

A referenced block was not found in storage.
"""
struct MissingBlockError <: ATProtoRepoError
    msg::String
end

Base.showerror(io::IO, err::MissingBlockError) =
    print(io, "MissingBlockError: ", err.msg)

"""
    BlockMap

An ordered in-memory collection of blocks: CID → bytes. Used to stage new
blocks before committing them to storage.
"""
struct BlockMap
    order::Vector{String}           # cid strings, insertion order
    map::Dict{String,Tuple{CID,Vector{UInt8}}}
end

BlockMap() = BlockMap(String[], Dict{String,Tuple{CID,Vector{UInt8}}}())

"Add a block; returns the map for chaining."
function put_block!(bm::BlockMap, cid::CID, bytes::AbstractVector{UInt8})
    key = string(cid)
    if !haskey(bm.map, key)
        push!(bm.order, key)
    end
    bm.map[key] = (cid, copy(bytes))
    return bm
end

put_blocks!(bm::BlockMap, other::BlockMap) =
    (for key in other.order; (cid, bytes) = other.map[key]; put_block!(bm, cid, bytes); end; bm)

Base.get(bm::BlockMap, cid::CID) = get(bm.map, string(cid), nothing)
Base.getindex(bm::BlockMap, cid::CID) = begin
    got = get(bm.map, string(cid), nothing)
    got === nothing && throw(KeyError(string(cid)))
    got
end
Base.haskey(bm::BlockMap, cid::CID) = haskey(bm.map, string(cid))
Base.length(bm::BlockMap) = length(bm.order)
Base.isempty(bm::BlockMap) = isempty(bm.order)

"Blocks in insertion order, as (cid, bytes) pairs."
function Base.iterate(bm::BlockMap, state = 1)
    state > length(bm.order) && return nothing
    bm.map[bm.order[state]], state + 1
end

"""
    AbstractBlockStore

Interface for block persistence: [`put_block!`](@ref), [`has_block`](@ref),
[`get_block`](@ref), [`read_obj`](@ref) (decode a DAG-CBOR block).
"""
abstract type AbstractBlockStore end

"Add the map's blocks to a persistent store."
put_blocks!(store::AbstractBlockStore, bm::BlockMap) =
    (for (cid, bytes) in bm; put_block!(store, cid, bytes); end; store)

"""
    MemoryBlockStore()

An in-memory `AbstractBlockStore`.
"""
struct MemoryBlockStore <: AbstractBlockStore
    blocks::Dict{String,Vector{UInt8}}
end

MemoryBlockStore() = MemoryBlockStore(Dict{String,Vector{UInt8}}())

function put_block!(store::MemoryBlockStore, cid::CID, bytes::AbstractVector{UInt8})
    store.blocks[string(cid)] = copy(bytes)
    return store
end

has_block(store::MemoryBlockStore, cid::CID) = haskey(store.blocks, string(cid))

function get_block(store::MemoryBlockStore, cid::CID)::Vector{UInt8}
    bytes = get(store.blocks, string(cid), nothing)
    bytes === nothing && throw(MissingBlockError("block not found: $(string(cid))"))
    return bytes
end

"Decode a stored DAG-CBOR block."
read_obj(store::AbstractBlockStore, cid::CID) = dag_cbor_decode(get_block(store, cid))

put_block!(store::AbstractBlockStore, cid::CID, bytes::AbstractVector{UInt8}) =
    (error("put_block! not implemented for $(typeof(store))"); store)
has_block(store::AbstractBlockStore, cid::CID) =
    (error("has_block not implemented for $(typeof(store))"); false)
get_block(store::AbstractBlockStore, cid::CID) =
    (error("get_block not implemented for $(typeof(store))"); UInt8[])
