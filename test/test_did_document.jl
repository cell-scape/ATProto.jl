using Test
using ATProto
using ATProto.DID
using ATProto.Crypto
using JSON

# a realistic did:plc document shape
const PLC_DID = "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
const SIGNING_DID_KEY = "did:key:zDnaevR4D8NGbfpBhCbA6x4dBiifhS2k7v1WyfePWgsqVXbwD"
const ROTATION_DID_KEY = "did:key:zQ3shokFTS3brHcDQrn82RUDfCZESWL1ZdCEJwekUDPQiYBme"

const PLC_DOC = JSON.parse("""
{
  "@context": [
    "https://www.w3.org/ns/did/v1",
    "https://w3id.org/security/multikey/v1"
  ],
  "id": "$PLC_DID",
  "alsoKnownAs": ["at://handle.example.com"],
  "verificationMethod": [
    {
      "id": "did:plc:ewvi7nx4oun5hl7s6yqkgcto#atproto",
      "type": "Multikey",
      "controller": "$PLC_DID",
      "publicKeyMultibase": "$(SIGNING_DID_KEY[length("did:key:")+1:end])"
    }
  ],
  "service": [
    {
      "id": "#atproto_pds",
      "type": "AtprotoPersonalDataServer",
      "serviceEndpoint": "https://pds.example.com"
    },
    {
      "id": "#bsky_fg",
      "type": "BskyFeedGenerator",
      "serviceEndpoint": "https://feedgen.example.com"
    }
  ],
  "rotationKeys": ["$ROTATION_DID_KEY"]
}
""")

@testset "DID document parsing" begin
    doc = parse_did_document(PLC_DID, PLC_DOC)
    @test get_did(doc) == PLC_DID
    @test get_handle(doc) == "handle.example.com"
    @test get_signing_key(doc) == SIGNING_DID_KEY
    @test get_pds_endpoint(doc) == "https://pds.example.com"
    @test get_feed_gen_endpoint(doc) == "https://feedgen.example.com"
    @test get_notif_endpoint(doc) === nothing

    data = ensure_atproto_data(doc)
    @test data isa AtprotoData
    @test data.did == PLC_DID
    @test data.signing_key == SIGNING_DID_KEY
    @test data.handle == "handle.example.com"
    @test data.pds == "https://pds.example.com"

    # parse from raw JSON bytes
    doc2 = parse_did_document(PLC_DID, Vector{UInt8}(codeunits(JSON.json(PLC_DOC))))
    @test get_pds_endpoint(doc2) == "https://pds.example.com"
end

@testset "DID document errors" begin
    # id mismatch
    bad = Dict{String,Any}(copy(PLC_DOC))
    bad["id"] = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    @test_throws ATProtoDidError parse_did_document(PLC_DID, bad)

    # missing id
    @test_throws ArgumentError parse_did_document(PLC_DID, Dict{String,Any}())

    # duplicate service ids
    dup = Dict{String,Any}(copy(PLC_DOC))
    dup["service"] = [
        Dict("id" => "#atproto_pds", "type" => "T", "serviceEndpoint" => "https://a"),
        Dict("id" => "did:plc:ewvi7nx4oun5hl7s6yqkgcto#atproto_pds", "type" => "T", "serviceEndpoint" => "https://b"),
    ]
    @test_throws ArgumentError parse_did_document(PLC_DID, dup)

    # malformed service
    badsvc = Dict{String,Any}(copy(PLC_DOC))
    badsvc["service"] = [Dict("id" => "#x")]
    @test_throws ArgumentError parse_did_document(PLC_DID, badsvc)
end

@testset "atproto data extraction edge cases" begin
    # no alsoKnownAs -> no handle
    minimal = Dict{String,Any}(
        "id" => PLC_DID,
        "verificationMethod" => PLC_DOC["verificationMethod"],
        "service" => PLC_DOC["service"],
    )
    doc = parse_did_document(PLC_DID, minimal)
    @test get_handle(doc) === nothing
    @test_throws ArgumentError ensure_atproto_data(doc)  # missing handle

    # EcdsaSecp256k1VerificationKey2019-style signing key (legacy DID docs)
    key = generate_key(Secp256k1Key)
    legacy = Dict{String,Any}(
        "id" => PLC_DID,
        "alsoKnownAs" => ["at://handle.example.com"],
        "verificationMethod" => [Dict(
            "id" => "$PLC_DID#atproto",
            "type" => "EcdsaSecp256k1VerificationKey2019",
            "controller" => PLC_DID,
            "publicKeyMultibase" => "z" * base58btc_encode(compress_pubkey(public_key_bytes(key); jwt_alg = "ES256K")),
        )],
        "service" => PLC_DOC["service"],
    )
    doc2 = parse_did_document(PLC_DID, legacy)
    @test get_signing_key(doc2) == did_key(key)
end
