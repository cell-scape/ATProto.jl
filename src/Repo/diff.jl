# Tree diffs. Port of `packages/repo/src/mst/diff.ts` at leaf granularity:
# walking both trees' in-order leaf streams and merge-comparing them (the
# same leaf-level semantics as the TS two-walker algorithm).

"""
    DataDiff

The leaf-level difference between two MST states: record adds, updates, and
deletes (with old/new CIDs).
"""
struct DataDiff
    adds::Vector{Pair{String,CID}}
    updates::Vector{Tuple{String,CID,CID}}  # key, old cid, new cid
    deletes::Vector{Pair{String,CID}}
end

DataDiff() = DataDiff(Pair{String,CID}[], Tuple{String,CID,CID}[], Pair{String,CID}[])

function Base.isempty(d::DataDiff)
    return isempty(d.adds) && isempty(d.updates) && isempty(d.deletes)
end

function Base.show(io::IO, d::DataDiff)
    print(io, "DataDiff(+$(length(d.adds)) ~$(length(d.updates)) -$(length(d.deletes)))")
end

"""
    mst_diff(curr, prev=nothing) -> DataDiff

Diff two MST states at leaf granularity. `prev === nothing` diffs against an
empty tree (everything is an add).
"""
function mst_diff(curr::MST, prev::Union{MST,Nothing} = nothing)::DataDiff
    prev === nothing && return _null_diff(curr)
    left = mst_leaves(prev)    # in key order
    right = mst_leaves(curr)
    diff = DataDiff()
    i = j = 1
    while i <= length(left) || j <= length(right)
        if i > length(left)
            push!(diff.adds, right[j].key => right[j].value); j += 1
        elseif j > length(right)
            push!(diff.deletes, left[i].key => left[i].value); i += 1
        elseif left[i].key == right[j].key
            left[i].value != right[j].value &&
                push!(diff.updates, (left[i].key, left[i].value, right[j].value))
            i += 1; j += 1
        elseif left[i].key < right[j].key
            push!(diff.deletes, left[i].key => left[i].value); i += 1
        else
            push!(diff.adds, right[j].key => right[j].value); j += 1
        end
    end
    return diff
end

function _null_diff(tree::MST)::DataDiff
    diff = DataDiff()
    for leaf in mst_leaves(tree)
        push!(diff.adds, leaf.key => leaf.value)
    end
    return diff
end
