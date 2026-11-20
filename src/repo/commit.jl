# Commit structures: creation, loading, signing, and chain verification.
# Port of the commit handling in `packages/repo/src/repo.ts` and
# `indigo/repo` (atproto repo spec: atproto.com/specs/repository).
#
# A commit is a DAG-CBOR object:
#   { did, version: 3, data: <mst root cid>, rev: <tid>, prev: <cid|null>, sig }
# where sig is a 64-byte compact ES256K signature over
# sha256(dag-cbor(commit without sig)).

const COMMIT_SIG_BYTES = 64

"Load a commit object from storage."
function load_commit(storage::AbstractBlockStore, cid::CID)
    commit = read_obj(storage, cid)
    commit isa AbstractDict && haskey(commit, "did") &&
        haskey(commit, "data") && haskey(commit, "rev") ||
        throw(ArgumentError("not a valid commit: $cid"))
    return commit
end

"The unsigned form of a commit (sig removed) as canonical DAG-CBOR bytes."
unsigned_commit_bytes(commit::AbstractDict) = begin
    unsigned = Dict{String,Any}()
    for (k, v) in commit
        k == "sig" || (unsigned[String(k)] = v)
    end
    dag_cbor_encode(unsigned)
end

"Digest a commit is signed over."
commit_digest(commit::AbstractDict) = sha256(unsigned_commit_bytes(commit))

"""
    create_commit(storage, root, did, rev; prev=nothing, signing_key) -> (CID, Vector{UInt8}, BlockMap)

Build and sign a new commit. `signing_key` is a `Secp256k1Key`. Returns the
commit CID, its bytes, and the MST's unstored blocks (caller persists both).
"""
function create_commit(storage::AbstractBlockStore, root::CID, did::AbstractString,
                       rev::AbstractString; prev::Union{CID,Nothing} = nothing,
                       signing_key)
    commit = Dict{String,Any}(
        "did" => String(did),
        "version" => 3,
        "data" => root,
        "rev" => String(rev),
        "prev" => prev,
    )
    sig = sign_digest(signing_key, commit_digest(commit))
    commit["sig"] = DagBytes(sig)
    bytes = dag_cbor_encode(commit)
    return (cid = cid_for_dagcbor(bytes), bytes = bytes)
end

"""
    verify_commit_sig(commit; signing_key_did) -> Bool

Verify a commit's signature against a `did:key:z...` signing key
(ES256K compact, low-S).
"""
function verify_commit_sig(commit::AbstractDict; signing_key_did::AbstractString)::Bool
    sig = get(commit, "sig", nothing)
    sig isa DagBytes || return false
    length(sig.bytes) == COMMIT_SIG_BYTES || return false
    digest = commit_digest(commit)
        parsed = parse_did_key(String(signing_key_did))
    return verify_sig_digest(parsed.key_bytes, digest, sig.bytes;
                             jwt_alg = parsed.jwt_alg)
end

"""
    verify_commit_chain(storage, latest_cid, signing_key_did; verify_all=true) -> Vector{CID}

Walk the `prev` chain from a commit backwards, verifying each signature (and
each block's presence). Returns the chain (latest first). Throws
`MissingBlockError` / `ArgumentError` on failures.
"""
function verify_commit_chain(storage::AbstractBlockStore, latest::CID,
                             signing_key_did::AbstractString;
                             verify_all::Bool = true)::Vector{CID}
    chain = CID[]
    current = latest
    seen = Set{String}()
    while current !== nothing
        string(current) in seen && throw(ArgumentError("commit cycle at $(string(current))"))
        push!(seen, string(current))
        commit = load_commit(storage, current)
        verify_commit_sig(commit; signing_key_did) ||
            throw(ArgumentError("invalid commit signature at $(string(current))"))
        push!(chain, current)
        verify_all || break
        prev = get(commit, "prev", nothing)
        current = prev isa CID ? prev : nothing
    end
    return chain
end
