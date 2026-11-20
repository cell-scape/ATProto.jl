```@meta
CurrentModule = ATProto
```

# DAG-CBOR Codec

`ATProto.DagCbor` implements the IPLD [DAG-CBOR](https://ipld.io/specs/codecs/dag-cbor/spec/)
canonical binary serialization format used for signed AT Protocol commits, Merkle Search
Tree (MST) nodes, PLC genesis operations, and CID links (CBOR tag 42).

```@autodocs
Modules = [ATProto.DagCbor]
Order = [:type, :function, :constant]
```
