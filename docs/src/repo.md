```@meta
CurrentModule = ATProto
```

# Repositories, MST & CAR Archives

`ATProto.Repo` implements the AT Protocol data repository stack: deterministic Merkle
Search Trees (`MST`), block stores (`MemoryBlockStore`, `BlockMap`), MST diffs
(`mst_diff`), CAR v1/v2 archive reading & writing (`read_car`, `write_car`,
`write_car_v2`), and signed v3 repository commits (`create_commit`, `load_commit`,
`verify_commit_sig`, `verify_commit_chain`).

```@autodocs
Modules = [ATProto.Repo]
Order = [:type, :function, :constant]
```
