```@meta
CurrentModule = ATProto
```

# OAuth 2.1 (PKCE + DPoP + PAR) & Service Auth

`ATProto.OAuth` implements AT Protocol OAuth 2.1 authentication — PKCE (`S256`), DPoP
proof JWTs (RFC 9449), `ES256`/`ES256K` JWK export & thumbprints, authorization server
discovery, Pushed Authorization Requests (PAR), DPoP-bound `OAuthSession` requests and
`AtpAgent(oauth)` transport integration, and inter-service JWT authentication
(`create_service_jwt`, `verify_service_jwt`).

```@autodocs
Modules = [ATProto.OAuth]
Order = [:type, :function, :constant]
```
