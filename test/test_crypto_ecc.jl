using Test
using ATProto
using ATProto.Crypto

include(joinpath(@__DIR__, "fixtures", "reference_fixtures.jl"))

@testset "did:key and multikey" begin
    @testset "parse/format (reference vectors)" begin
        for v in FIXTURES.keys
            parsed = parse_did_key(v.did_key)
            @test parsed.jwt_alg == v.jwt_alg
            @test parsed.key_bytes == hex2bytes(v.pub_uncompressed)

            # formatting from the uncompressed key round-trips exactly
            @test format_did_key(v.jwt_alg, hex2bytes(v.pub_uncompressed)) == v.did_key
            # the multikey form is the did:key body after the prefix
            multikey = v.did_key[length("did:key:")+1:end]
            @test format_multikey(v.jwt_alg, hex2bytes(v.pub_uncompressed)) == multikey
            @test parse_multikey(multikey).key_bytes == hex2bytes(v.pub_uncompressed)
        end
    end

    @testset "pubkey compression" begin
        for v in FIXTURES.keys
            unc = hex2bytes(v.pub_uncompressed)
            comp = hex2bytes(v.pub_compressed)
            @test compress_pubkey(unc; jwt_alg = v.jwt_alg) == comp
            @test decompress_pubkey(comp; jwt_alg = v.jwt_alg) == unc
            @test_throws ArgumentError decompress_pubkey(UInt8[0x02]; jwt_alg = v.jwt_alg)
        end
    end

    @testset "errors" begin
        @test_throws InvalidMultikeyError parse_did_key("did:plc:abc123")
        @test_throws InvalidMultikeyError parse_multikey("f0011")   # wrong multibase prefix
        @test_throws UnsupportedKeyTypeError format_did_key("Ed25519", hex2bytes("00"^16))
    end
end

@testset "ECDSA keys" begin
    @testset "import & derive (reference vectors)" begin
        for (T, v) in ((P256Key, FIXTURES.keys[1]), (Secp256k1Key, FIXTURES.keys[2]))
            key = import_key(T, v.priv_hex)
            @test public_key_bytes(key) == hex2bytes(v.pub_uncompressed)
            @test private_key_bytes(key) == hex2bytes(v.priv_hex)
            @test jwt_alg(key) == v.jwt_alg
            @test did_key(key) == v.did_key

            # import from bytes too
            key2 = import_key(T, hex2bytes(v.priv_hex))
            @test public_key_bytes(key2) == public_key_bytes(key)

            @test_throws ArgumentError import_key(T, UInt8[])
            @test_throws ArgumentError import_key(T, zeros(UInt8, 32))
        end
    end

    @testset "verify noble signatures" begin
        for v in FIXTURES.keys
            data = hex2bytes(v.data_hex)
            sig = hex2bytes(v.sig_compact)
            @test length(sig) == 64
            @test sha256(data) == hex2bytes(v.msg_hash)

            # against the uncompressed public key
            @test verify_sig(hex2bytes(v.pub_uncompressed), data, sig; jwt_alg = v.jwt_alg)
            # against the did:key
            @test verify_did_sig(v.did_key, data, sig)
            # tampered data must fail
            @test !verify_did_sig(v.did_key, vcat(data, 0x00), sig)
            # tampered signature must fail
            bad = copy(sig); bad[10] ⊻= 0xff
            @test !verify_did_sig(v.did_key, data, bad)
            # wrong curve must fail
            other_alg = v.jwt_alg == "ES256" ? "ES256K" : "ES256"
            @test !verify_sig(hex2bytes(v.pub_uncompressed), data, sig; jwt_alg = other_alg)
        end
    end

    @testset "sign & verify round-trip" begin
        for T in (P256Key, Secp256k1Key)
            key = generate_key(T)
            @test public_key_bytes(key) |> length == 65
            @test startswith(did_key(key), "did:key:z")
            msg = collect(codeunits("atproto sign/verify round trip"))
            sig = sign_message(key, msg)
            @test length(sig) == 64
            @test verify_sig(public_key_bytes(key), msg, sig; jwt_alg = jwt_alg(key))
            @test verify_did_sig(did_key(key), msg, sig)
            @test !verify_did_sig(did_key(key), codeunits("different message"), sig)

            # deterministic import → same did, and cross-instance verify
            key_b = import_key(T, private_key_bytes(key))
            @test did_key(key_b) == did_key(key)
            @test verify_did_sig(did_key(key_b), msg, sig)
        end
    end

    @testset "strictness" begin
        v = FIXTURES.keys[2]  # secp256k1
        data = hex2bytes(v.data_hex)
        sig = hex2bytes(v.sig_compact)
        pub = hex2bytes(v.pub_uncompressed)

        # non-64-byte (DER-like) signatures rejected in strict mode
        der = vcat(UInt8(0x30), UInt8(0x02), UInt8(0x19), sig[1:25])
        @test !verify_sig(pub, data, der; jwt_alg = v.jwt_alg)
        # accepted when malleable allowed... (still fails verification, but no
        # length rejection happens — verified via a truncated 63-byte sig)
        short = sig[1:63]
        @test !verify_sig(pub, data, short; jwt_alg = v.jwt_alg)
        @test !verify_sig(pub, data, short; jwt_alg = v.jwt_alg, allow_malleable = true)

        # high-S rejection: flip s to n - s
        s = sig[33:64]
        n_minus_s = hex2bytes(lpad(string(parse(BigInt, "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"; base = 16) -
                                        parse(BigInt, bytes2hex(s); base = 16); base = 16), 64, '0'))
        high_s = vcat(sig[1:32], n_minus_s)
        @test !verify_sig(pub, data, high_s; jwt_alg = v.jwt_alg)                          # strict rejects high-S
        @test verify_sig(pub, data, high_s; jwt_alg = v.jwt_alg, allow_malleable = true)   # (r, n-s) is mathematically valid: ECDSA malleability
    end
end
