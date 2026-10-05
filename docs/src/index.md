# API Reference

```@meta
CurrentModule = ATProto
```

# ATProto.jl

A feature-complete AT Protocol SDK for Julia.

## Overview

```@docs
ATProto
```

## Syntax

Identifier and primitive syntax validation.

```@docs
ATProto.Syntax.is_valid_did
ATProto.Syntax.is_valid_handle
ATProto.Syntax.is_valid_nsid
ATProto.Syntax.is_valid_tid
ATProto.Syntax.is_valid_record_key
ATProto.Syntax.is_valid_at_identifier
ATProto.Syntax.AtURI
ATProto.Syntax.at_uri
ATProto.Syntax.is_valid_datetime
ATProto.Syntax.datetime_string
ATProto.Syntax.parse_datetime
ATProto.Syntax.NSID
ATProto.Syntax.make_nsid
ATProto.Syntax.TID
```

## Crypto

Multibase, CID, hashing, ECDSA.

```@docs
ATProto.Crypto.multibase_to_bytes
ATProto.Crypto.bytes_to_multibase
ATProto.Crypto.CID
ATProto.Crypto.cid_parse
ATProto.Crypto.cid_for_dagcbor
ATProto.Crypto.sha256
ATProto.Crypto.ripemd160
ATProto.Crypto.parse_did_key
ATProto.Crypto.format_did_key
ATProto.Crypto.P256Key
ATProto.Crypto.Secp256k1Key
ATProto.Crypto.generate_key
ATProto.Crypto.import_key
ATProto.Crypto.sign_message
ATProto.Crypto.verify_sig
ATProto.Crypto.recover_pubkey
```

## DAG-CBOR

Canonical CBOR encoding/decoding with CID support.

```@docs
ATProto.DagCbor.dag_cbor_encode
ATProto.DagCbor.dag_cbor_decode
ATProto.DagCbor.DagBytes
```

## DID

DID document parsing, resolvers, PLC verification.

```@docs
ATProto.DID.is_did_plc
ATProto.DID.is_did_web
ATProto.DID.is_atproto_did
ATProto.DID.DidResolver
ATProto.DID.resolve_document
ATProto.DID.resolve_atproto_data
ATProto.DID.PlcClient
ATProto.DID.verify_legacy_create
ATProto.DID.verify_operation
```

## Identity

Handle resolution and bidirectional identity verification.

```@docs
ATProto.Identity.HandleResolver
ATProto.Identity.resolve_handle
ATProto.Identity.IdResolver
ATProto.Identity.resolve_identity
```

## XRPC

XRPC client protocol.

```@docs
ATProto.XRPC.XRPCClient
ATProto.XRPC.xrpc_get
ATProto.XRPC.xrpc_proc
ATProto.XRPC.serialize_lex
ATProto.XRPC.parse_lex
ATProto.XRPC.AuthSession
ATProto.XRPC.SessionClient
ATProto.XRPC.create_session
```

## Lexicon

Lexicon document validation and value validation.

```@docs
ATProto.Lexicon.Lexicons
ATProto.Lexicon.add_lexicon!
ATProto.Lexicon.get_def
ATProto.Lexicon.validate_lex_ref_variant
ATProto.Lexicon.assert_valid_record
ATProto.Lexicon.BlobRef
ATProto.Lexicon.blob_ref_from_json
```

## Repo

Merkle Search Tree, CAR archives, commits.

```@docs
ATProto.Repo.MST
ATProto.Repo.mst_create
ATProto.Repo.mst_add
ATProto.Repo.mst_get
ATProto.Repo.mst_update
ATProto.Repo.mst_delete
ATProto.Repo.mst_pointer
ATProto.Repo.mst_leaves
ATProto.Repo.mst_diff
ATProto.Repo.read_car
ATProto.Repo.write_car
ATProto.Repo.create_commit
ATProto.Repo.verify_commit_chain
ATProto.Repo.BlockMap
ATProto.Repo.MemoryBlockStore
```

## API

Generated client and agent conveniences.

```@docs
ATProto.API.Agent
ATProto.API.SessionAgent
ATProto.API.login
ATProto.API.create_record
ATProto.API.create_post
ATProto.API.upload_blob
ATProto.API.delete_post
```

## RichText

Facet detection and text manipulation.

```@docs
ATProto.RichText.RichText
ATProto.RichText.detect_facets
ATProto.RichText.segments
ATProto.RichText.insert_text!
ATProto.RichText.delete_text!
```

## OAuth

PKCE, DPoP, JWT.

```@docs
ATProto.OAuth.generate_pkce
ATProto.OAuth.generate_dpop_key
ATProto.OAuth.build_dpop_proof
ATProto.OAuth.OAuthClientMetadata
ATProto.OAuth.validate_client_metadata
ATProto.OAuth.build_authorization_url
ATProto.OAuth.exchange_code
ATProto.OAuth.OAuthSession
ATProto.OAuth.oauth_request
```

## Jetstream

Firehose events and WebSocket subscription.

```@docs
ATProto.Jetstream.FirehoseEvent
ATProto.Jetstream.CommitEvent
ATProto.Jetstream.parse_firehose_frame
ATProto.Jetstream.jetstream_subscribe
```
