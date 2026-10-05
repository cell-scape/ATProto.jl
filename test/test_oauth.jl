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
    @test JSON.parse(String(copy(res.body)))["ok"] == true
end
