```@meta
CurrentModule = ATProto
```

# Lexicon Schema Validation

`ATProto.Lexicon` parses AT Protocol Lexicon JSON schema documents at runtime, resolves
cross-document `#ref` and open/closed union variants, and validates records, XRPC query
parameters, procedure inputs, and outputs (`assert_valid_record`,
`assert_valid_xrpc_params`, `assert_valid_xrpc_input`, `assert_valid_xrpc_output`).

```@autodocs
Modules = [ATProto.Lexicon]
Order = [:type, :function, :constant]
```
