using Test
using ATProto
using ATProto.OAuth
using ATProto.Crypto
using HTTP
using JSON

@testset "PKCE" begin
    pkce = generate_pkce()
    @test length(pkce.verifier) >= 43  # 32 bytes → 43 base64url chars
    @test length(pkce.verifier) <= 128
    @test pkce.method == "S256"
    @test pkce.challenge == base64url_encode(sha256(pkce.verifier))
    # deterministic length
    @test length(generate_pkce(64).verifier) == 86  # 64 bytes → ceil(64*4/3) = 86
    @test_throws ArgumentError generate_pkce(31)
    @test_throws ArgumentError generate_pkce(97)
    # different each time
    @test generate_pkce().verifier != generate_pkce().verifier
end

@testset "JWK export" begin
    key_k = generate_key(Secp256k1Key)
    jwk = jwk_public_key(key_k)
    @test jwk["kty"] == "EC"
    @test jwk["crv"] == "secp256k1"
    @test haskey(jwk, "x") && haskey(jwk, "y")
    @test length(base64url_decode(jwk["x"])) == 32
    @test length(base64url_decode(jwk["y"])) == 32

    key_p = generate_key(P256Key)
    jwk_p = jwk_public_key(key_p)
    @test jwk_p["kty"] == "EC"
    @test jwk_p["crv"] == "P-256"

    # thumbprint is deterministic and 43 chars (sha256 base64url)
    tp = jwk_thumbprint(jwk)
    @test length(tp) == 43
    @test jwk_thumbprint(jwk) == tp
    @test jwk_thumbprint(jwk_p) != tp  # different keys → different thumbprints
end

@testset "JWT sign/verify round trip" begin
    key_k = generate_key(Secp256k1Key)
    header = Dict{String,Any}("typ" => "dpop+jwt", "alg" => "ES256K")
    payload = Dict{String,Any}("htm" => "POST", "htu" => "https://pds.example.com/xrpc/com.atproto.server.getSession")
    token = sign_jwt_es256k(key_k, header, payload)

    parts = split(token, '.')
    @test length(parts) == 3
    decoded_h = JSON.parse(String(base64url_decode(String(parts[1]))))
    decoded_p = JSON.parse(String(base64url_decode(String(parts[2]))))
    @test decoded_h["alg"] == "ES256K"
    @test decoded_p["htm"] == "POST"

    # verify with the right key
    @test verify_jwt_es256k(token, public_key_bytes(key_k))
    # wrong key fails
    other = generate_key(Secp256k1Key)
    @test !verify_jwt_es256k(token, public_key_bytes(other))
    # tampered payload fails
    tampered = parts[1] * "." * base64url_encode(Vector{UInt8}(codeunits(
        replace(JSON.json(payload), "POST" => "GET")))) * "." * parts[3]
    @test !verify_jwt_es256k(tampered, public_key_bytes(key_k))

    # ES256 round trip
    key_p = generate_key(P256Key)
    h2 = Dict{String,Any}("typ" => "dpop+jwt", "alg" => "ES256")
    token_p = sign_jwt_es256(key_p, h2, payload)
    @test verify_jwt_es256(token_p, public_key_bytes(key_p))
    @test !verify_jwt_es256(token_p, public_key_bytes(generate_key(P256Key)))
end

@testset "DPoP proof" begin
    key = generate_dpop_key(; alg = "ES256K")
    proof = build_dpop_proof(key, "POST", "https://pds.example.com/xrpc/com.atproto.repo.createRecord")
    parts = split(proof, '.')
    header = JSON.parse(String(base64url_decode(String(parts[1]))))
    payload = JSON.parse(String(base64url_decode(String(parts[2]))))

    @test header["typ"] == "dpop+jwt"
    @test header["alg"] == "ES256K"
    @test header["jwk"]["kty"] == "EC"

    @test payload["htm"] == "POST"
    @test payload["htu"] == "https://pds.example.com/xrpc/com.atproto.repo.createRecord"
    @test haskey(payload, "iat")
    @test haskey(payload, "jti")

    # htu strips query and fragment
    proof2 = build_dpop_proof(key, "GET", "https://pds.example.com/path?query=1#frag")
    payload2 = JSON.parse(String(base64url_decode(String(split(proof2, '.')[2]))))
    @test payload2["htu"] == "https://pds.example.com/path"

    # with nonce and access token
    proof3 = build_dpop_proof(key, "POST", "https://pds.example.com/tokens";
                              nonce = "server-nonce", access_token = "my-token")
    payload3 = JSON.parse(String(base64url_decode(String(split(proof3, '.')[2]))))
    @test payload3["nonce"] == "server-nonce"
    @test payload3["ath"] == base64url_encode(sha256("my-token"))

    # proofs verify
    @test verify_jwt_es256k(proof, public_key_bytes(key))
end

@testset "client metadata validation" begin
    good = OAuthClientMetadata(;
        client_id = "https://app.example.com/oauth/client-metadata.json",
        redirect_uris = ["https://app.example.com/callback"])
    @test validate_client_metadata(good).client_id == good.client_id

    # missing atproto scope
    bad1 = OAuthClientMetadata(;
        client_id = "https://app.example.com", redirect_uris = ["https://a.b/c"],
        scope = "profile")
    @test_throws ArgumentError validate_client_metadata(bad1)

    # wrong response type
    bad2 = OAuthClientMetadata(;
        client_id = "https://app.example.com", redirect_uris = ["https://a.b/c"],
        response_types = ["token"])
    @test_throws ArgumentError validate_client_metadata(bad2)

    # private_key_jwt without jwks
    bad3 = OAuthClientMetadata(;
        client_id = "https://app.example.com", redirect_uris = ["https://a.b/c"],
        token_endpoint_auth_method = "private_key_jwt")
    @test_throws ArgumentError validate_client_metadata(bad3)

    # JSON round trip
    json = client_metadata_to_json(good)
    @test json["client_id"] == good.client_id
    @test json["scope"] == "atproto"
    @test json["dpop_bound_access_tokens"] == true
end

@testset "authorization URL" begin
    url = build_authorization_url(
        "https://auth.example.com/authorize",
        "https://app.example.com/client",
        "https://app.example.com/callback";
        code_challenge = "challenge123",
        state = "state456",
        login_hint = "alice.example.com")
    @test startswith(url, "https://auth.example.com/authorize?")
    @test occursin("client_id=https%3A%2F%2Fapp.example.com%2Fclient", url)
    @test occursin("response_type=code", url)
    @test occursin("code_challenge=challenge123", url)
    @test occursin("code_challenge_method=S256", url)
    @test occursin("state=state456", url)
    @test occursin("login_hint=alice.example.com", url)
    @test occursin("scope=atproto", url)
end

@testset "token exchange with canned server" begin
    calls = Tuple{String,String,String}[]
    fetch(method, url, headers, body; timeout = 30.0) = begin
        dpop = ""
        for (k, v) in headers
            lowercase(String(k)) == "dpop" && (dpop = String(v))
        end
        push!(calls, (String(method), String(url), dpop))
        return HTTP.Response(200, ["Content-Type" => "application/json"],
            Vector{UInt8}(codeunits(
                """{"access_token":"at-123","refresh_token":"rt-456","token_type":"DPoP","expires_in":3600,"sub":"did:plc:abc"}""")))
    end

    dpop_key = generate_dpop_key()
    result = exchange_code("https://auth.example.com/token",
                           "https://app.example.com/client",
                           "https://app.example.com/callback",
                           "auth-code-xyz", "verifier-abc";
                           dpop_key = dpop_key, fetch = fetch)
    @test result["access_token"] == "at-123"
    @test result["refresh_token"] == "rt-456"
    @test result["sub"] == "did:plc:abc"

    # DPoP proof was sent
    method, url, dpop = calls[1]
    @test method == "POST"
    @test url == "https://auth.example.com/token"
    @test !isempty(dpop)
    # the proof is a valid JWT
    @test verify_jwt_es256k(dpop, public_key_bytes(dpop_key))
end

@testset "OAuth session requests" begin
    request_count = Ref(0)
    nonce_count = Ref(0)
    fetch(method, url, headers, body; timeout = 30.0) = begin
        request_count[] += 1
        # first request: 401 with nonce → second: 200
        if request_count[] == 1
            nonce_count[] += 1
            return HTTP.Response(401,
                ["Content-Type" => "application/json", "DPoP-Nonce" => "fresh-nonce"],
                Vector{UInt8}(codeunits("""{"error":"use_dpop_nonce"}""")))
        end
        return HTTP.Response(200, ["Content-Type" => "application/json"],
            Vector{UInt8}(codeunits("""{"ok":true}""")))
    end

    session = OAuthSession(;
        client_id = "https://app.example.com/client",
        token_endpoint = "https://auth.example.com/token",
        dpop_key = generate_dpop_key(),
        access_token = "token-1",
        refresh_token = "refresh-1",
        fetch = fetch)

    res = oauth_request(session, "GET", "https://pds.example.com/xrpc/com.atproto.server.getSession")
    @test res.status == 200
    @test request_count[] == 2  # retried with nonce
    @test JSON.parse(res.body isa String ? res.body : String(copy(res.body)))["ok"] == true
end

@testset "RFC 7638 JWK thumbprint canonical JSON" begin
    key = generate_key(P256Key)
    jwk = jwk_public_key(key)
    expected_json = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"$(jwk["x"])\",\"y\":\"$(jwk["y"])\"}"
    @test jwk_thumbprint(jwk) == base64url_encode(sha256(expected_json))
end

@testset "OAuth 2.1 Discovery, PAR, DPoP-Nonce retry & AtpAgent integration" begin
    par_attempts = Ref(0)
    token_attempts = Ref(0)
    fetch_fn = function (method, url, headers, body; timeout = 30.0)
        if endswith(url, "/.well-known/oauth-protected-resource")
            return HTTP.Response(200, ["Content-Type" => "application/json"],
                Vector{UInt8}(codeunits("""{"resource":"https://pds.example","authorization_servers":["https://auth.example"]}""")))
        elseif endswith(url, "/.well-known/oauth-authorization-server")
            return HTTP.Response(200, ["Content-Type" => "application/json"],
                Vector{UInt8}(codeunits("""{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/oauth/authorize","token_endpoint":"https://auth.example/oauth/token","pushed_authorization_request_endpoint":"https://auth.example/oauth/par"}""")))
        elseif endswith(url, "/oauth/par")
            par_attempts[] += 1
            if par_attempts[] == 1
                return HTTP.Response(400, ["Content-Type" => "application/json", "DPoP-Nonce" => "par-nonce-1"],
                    Vector{UInt8}(codeunits("""{"error":"use_dpop_nonce"}""")))
            end
            return HTTP.Response(201, ["Content-Type" => "application/json"],
                Vector{UInt8}(codeunits("""{"request_uri":"urn:ietf:params:oauth:request_uri:req-99","expires_in":90}""")))
        elseif endswith(url, "/oauth/token")
            token_attempts[] += 1
            if token_attempts[] == 1
                return HTTP.Response(400, ["Content-Type" => "application/json", "DPoP-Nonce" => "tok-nonce-1"],
                    Vector{UInt8}(codeunits("""{"error":"use_dpop_nonce"}""")))
            end
            return HTTP.Response(200, ["Content-Type" => "application/json"],
                Vector{UInt8}(codeunits("""{"access_token":"oauth-at-1","refresh_token":"oauth-rt-1","token_type":"DPoP","sub":"did:plc:z72i7hdynmk6r22z27h6tvur"}""")))
        elseif occursin("/xrpc/app.bsky.actor.getProfile", url)
            has_dpop = any(lowercase(k) == "dpop" for (k, _) in headers)
            has_auth = any(lowercase(k) == "authorization" && startswith(v, "DPoP ") for (k, v) in headers)
            (has_dpop && has_auth) || return HTTP.Response(401)
            return HTTP.Response(200, ["Content-Type" => "application/json"],
                Vector{UInt8}(codeunits("""{"did":"did:plc:z72i7hdynmk6r22z27h6tvur","handle":"bsky.app"}""")))
        end
        return HTTP.Response(404)
    end

    meta = discover_authorization_server("https://pds.example"; fetch = fetch_fn)
    @test meta["issuer"] == "https://auth.example"

    pkce = generate_pkce()
    dpop_key = generate_dpop_key()
    par = pushed_authorization_request(
        meta["pushed_authorization_request_endpoint"],
        "https://app.example/client-metadata.json",
        "https://app.example/callback";
        code_challenge = pkce.challenge,
        state = "st-1",
        dpop_key = dpop_key,
        fetch = fetch_fn,
    )
    @test par_attempts[] == 2
    @test par["request_uri"] == "urn:ietf:params:oauth:request_uri:req-99"

    auth_url = build_par_authorization_url(meta["authorization_endpoint"], "https://app.example/client-metadata.json", par["request_uri"])
    @test occursin("request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Areq-99", auth_url)

    toks = exchange_code(
        meta["token_endpoint"],
        "https://app.example/client-metadata.json",
        "https://app.example/callback",
        "code-abc",
        pkce.verifier;
        dpop_key = dpop_key,
        fetch = fetch_fn,
    )
    @test token_attempts[] == 2
    @test toks["access_token"] == "oauth-at-1"

    oauth_sess = OAuthSession(;
        client_id = "https://app.example/client-metadata.json",
        token_endpoint = meta["token_endpoint"],
        dpop_key = dpop_key,
        access_token = toks["access_token"],
        refresh_token = toks["refresh_token"],
        did = toks["sub"],
        fetch = fetch_fn,
    )
    agent = AtpAgent(oauth_sess, "https://pds.example")
    prof = get_profile(agent, handle"bsky.app")
    @test prof.handle == handle"bsky.app"
end

@testset "Service Auth JWT creation & verification" begin
    iss = did"did:plc:z72i7hdynmk6r22z27h6tvur"
    aud = "did:web:feed.example.com"
    now_i = 1_800_000_000

    for K in (Secp256k1Key, P256Key)
        key = generate_key(K)
        dk = did_key(key)
        tok = create_service_jwt(iss, aud, key; lxm = nsid"app.bsky.feed.getFeedSkeleton", iat = now_i, exp = now_i + 60)
        claims = verify_service_jwt(
            tok;
            aud = aud,
            lxm = "app.bsky.feed.getFeedSkeleton",
            resolve_key = _ -> dk,
            now_ts = now_i + 10,
        )
        @test claims.iss == iss
        @test claims.aud == aud
        @test claims.lxm == nsid"app.bsky.feed.getFeedSkeleton"
        @test claims.exp == now_i + 60

        # Expired token fails
        @test_throws ServiceAuthError verify_service_jwt(tok; aud = aud, resolve_key = _ -> dk, now_ts = now_i + 120)
        # Wrong audience fails
        @test_throws ServiceAuthError verify_service_jwt(tok; aud = "did:web:other.example", resolve_key = _ -> dk, now_ts = now_i + 10)
        # Wrong lxm fails
        @test_throws ServiceAuthError verify_service_jwt(tok; aud = aud, lxm = "app.bsky.actor.getProfile", resolve_key = _ -> dk, now_ts = now_i + 10)
        # Wrong signing key fails
        other_dk = did_key(generate_key(K))
        @test_throws ServiceAuthError verify_service_jwt(tok; aud = aud, resolve_key = _ -> other_dk, now_ts = now_i + 10)
    end

    # End-to-end verification via IdentityResolver DIDDocument lookup
    key = generate_key(Secp256k1Key)
    multikey = format_multikey(jwt_alg(key), public_key_bytes(key))
    did_doc_json = JSON.json(Dict(
        "id" => String(iss),
        "verificationMethod" => [Dict(
            "id" => "$(iss)#atproto",
            "type" => "Multikey",
            "controller" => String(iss),
            "publicKeyMultibase" => multikey,
        )],
    ))
    resolver = ATProto.Identity.IdentityResolver(
        http_transport = (url, headers; timeout) -> HTTP.Response(200, ["Content-Type" => "application/json"], Vector{UInt8}(codeunits(did_doc_json))),
    )
    tok = create_service_jwt(iss, aud, key; iat = now_i, exp = now_i + 60)
    claims = verify_service_jwt(tok; aud = aud, resolver = resolver, now_ts = now_i + 5)
    @test claims.iss == iss
end
