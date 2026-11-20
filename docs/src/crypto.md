```@meta
CurrentModule = ATProto
```

# Cryptography, CIDs & Multibase

`ATProto.Crypto` provides the cryptographic and multiformat primitives required by the AT
Protocol: unsigned LEB128 varints, multibase encodings (`base16`, `base32`, `base58btc`,
`base64`/`base64url`), SHA-256 and RIPEMD-160 digests, CIDv1 parsing/creation, `did:key`
multikeys, public-key compression/recovery, and ECDSA signing & verification over both
`P-256` (`ES256`) and `secp256k1` (`ES256K`) via `OpenSSL_jll`.

```@autodocs
Modules = [ATProto.Crypto]
Order = [:type, :function, :constant]
```
