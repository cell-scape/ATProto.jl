using Test
using ATProto
using ATProto.DID
using ATProto.Crypto
using ATProto.DagCbor
using HTTP

include(joinpath(@__DIR__, "fixtures", "reference_fixtures.jl"))

@testset "ripemd160 (reference vectors)" begin
    for v in FIXTURES.ripemd160
        @test ripemd160(hex2bytes(v.input_hex)) == hex2bytes(v.digest_hex)
    end
end

@testset "secp256k1 pubkey recovery (noble vectors)" begin
    for v in FIXTURES.recovery
        @test recover_pubkey(hex2bytes(v.digest_hex), hex2bytes(v.sig65_hex)) ==
              hex2bytes(v.pub_uncompressed)
    end
    # malformed inputs
    @test_throws ArgumentError recover_pubkey(fill(0x00, 32), fill(0x00, 65))  # recid 0, r=0
    @test_throws ArgumentError recover_pubkey(fill(0x00, 32), UInt8[])  # too short
end

@testset "PLC operation verification" begin
    if !FIXTURES.plc.ripemd_available
        @warn "node ripemd160 unavailable at fixture generation; genesis DID test is self-consistent only"
    end

    genesis_bytes = hex2bytes(FIXTURES.plc.genesis_op_bytes)
    op = dag_cbor_decode(genesis_bytes)
    @test op isa Dict{String,Any}
    @test op["type"] == "plc1"

    # canonical re-encode reproduces the exact bytes
    @test dag_cbor_encode(op) == genesis_bytes

    # genesis DID derivation matches the cross-implementation fixture
    @test plc_genesis_did(op) == FIXTURES.plc.genesis_did

    # LegacyCreate verification: signed op recovers to a rotation key
    signed = Dict{String,Any}(op)
    signed["sig"] = FIXTURES.plc.legacy_create_sig
    @test verify_legacy_create(signed)
    @test verify_legacy_create(signed; expected_did = FIXTURES.plc.genesis_did)
    @test !verify_legacy_create(signed; expected_did = "did:plc:zzzzzzzzzzzzzzzzzzzzzzzz")
    tampered = Dict{String,Any}(signed)
    tampered["handle"] = "eve.example.com"
    @test !verify_legacy_create(tampered)
    @test !verify_legacy_create(op)  # unsigned

    # Operation verification: any valid rotation-key signature suffices
    op1 = dag_cbor_decode(hex2bytes(FIXTURES.plc.op1_bytes))
    @test dag_cbor_encode(op1) == hex2bytes(FIXTURES.plc.op1_bytes)
    signed_op1 = Dict{String,Any}(op1)
    signed_op1["sigs"] = collect(FIXTURES.plc.op1_sigs)
    rotation_keys = collect(FIXTURES.plc.rotation_keys)
    @test verify_operation(signed_op1, rotation_keys)
    @test !verify_operation(signed_op1, ["did:key:zQ3shokFTS3brHcDQrn82RUDfCZESWL1ZdCEJwekUDPQiYBme"])
    @test !verify_operation(op1, rotation_keys)  # unsigned
    tampered_op1 = Dict{String,Any}(signed_op1)
    tampered_op1["alsoKnownAs"] = Any["at://evil.example.com"]
    @test !verify_operation(tampered_op1, rotation_keys)
end

@testset "PlcClient" begin
    doc_body = read(joinpath(@__DIR__, "fixtures", "plc_doc.json"), String)
    did = "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
    calls = String[]
    fetch(url; headers = (), timeout = 3.0) = begin
        push!(calls, String(url))
        m = match(r"/log/last$", url)
        m !== nothing && return HTTP.Response(200, Vector{UInt8}(codeunits("""{"type":"plc1","prev":null}""")))
        return HTTP.Response(200, Vector{UInt8}(codeunits(doc_body)))
    end

    client = PlcClient(; fetch)
    doc = get_document(client, did)
    @test doc["id"] == did
    @test calls[end] == "https://plc.directory/" * HTTP.URIs.escapeuri(did)

    last_op = get_last_operation(client, did)
    @test last_op["type"] == "plc1"

    @test calls[1] == "https://plc.directory/" * HTTP.URIs.escapeuri(did)

    # 404 -> nothing
    fetch404(url; headers = (), timeout = 3.0) = HTTP.Response(404, UInt8[])
    @test get_document(PlcClient(; fetch = fetch404), did) === nothing
end
