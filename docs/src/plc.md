```@meta
CurrentModule = ATProto
```

# PLC Directory & DID Verification

`ATProto.PLC` provides low-level `did:plc` and `did:web` validation, `plc.directory` audit
log fetching, cryptographic verification of PLC operation chains (`plc_genesis_did`,
`verify_legacy_create`, `verify_operation`), in-memory DID document caching, and
signature verification against resolved DID documents.

```@autodocs
Modules = [ATProto.PLC]
Order = [:type, :function, :constant]
```
