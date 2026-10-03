using Test
using ATProto
using ATProto.DID

@testset "did:plc validation" begin
    @test is_did_plc("did:plc:ewvi7nx4oun5hl7s6yqkgcto")
    @test is_did_plc("did:plc:abcdefghijklmnopqrstuvwx")  # 24 chars [a-z2-7]
    @test !is_did_plc("did:plc:ewvi7nx4oun5hl7s6yqkgct")   # 23 chars
    @test !is_did_plc("did:plc:ewvi7nx4oun5hl7s6yqkgctoo") # 25 chars
    @test !is_did_plc("did:plc:0wvi7nx4oun5hl7s6yqkgcto")  # '0' not in alphabet
    @test !is_did_plc("did:plc:1wvi7nx4oun5hl7s6yqkgcto")  # '1'
    @test !is_did_plc("did:plc:8wvi7nx4oun5hl7s6yqkgcto")  # '8'
    @test !is_did_plc("did:plc:Wwvi7nx4oun5hl7s6yqkgcto")  # uppercase
    @test !is_did_plc("did:web:ewvi7nx4oun5hl7s6yqkgcto")
    @test !is_did_plc("")
    @test ensure_did_plc("did:plc:ewvi7nx4oun5hl7s6yqkgcto") == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
    @test_throws ATProtoDidError ensure_did_plc("did:plc:short")
end

@testset "did:web validation" begin
    @test is_did_web("did:web:example.com")
    @test is_did_web("did:web:localhost")
    @test is_did_web("did:web:example.com%3A8443")  # port: valid did:web syntax
    @test is_did_web("did:web:example.com:path")     # path: valid did:web syntax
    @test !is_did_web("did:web::example.com")        # leading colon
    @test !is_did_web("did:web:")
    @test !is_did_web("did:plc:example.com")
    @test !is_did_web("did:web:exa mple.com")

    @test build_did_web_url("did:web:example.com") == "https://example.com"
    @test build_did_web_url("did:web:localhost") == "http://localhost"
    @test build_did_web_url("did:web:localhost%3A25841") == "http://localhost:25841"
    @test build_did_web_url("did:web:example.com%3A8443") == "https://example.com:8443"
    @test build_did_web_url("did:web:example.com:path") == "https://example.com/path"
    @test did_web_to_url("did:web:example.com") == "https://example.com"
end

@testset "atproto DID validation" begin
    @test is_atproto_did("did:plc:ewvi7nx4oun5hl7s6yqkgcto")
    @test is_atproto_did("did:web:example.com")
    @test is_atproto_did("did:web:localhost")
    @test is_atproto_did("did:web:localhost%3A25841")  # localhost ports allowed
    @test !is_atproto_did("did:web:example.com%3A8443") # other ports not
    @test !is_atproto_did("did:web:example.com:path")   # paths not
    @test !is_atproto_did("did:key:zDnaevR4D8NGbfpBhCbA6x4dBiifhS2k7v1WyfePWgsqVXbwD")
    @test !is_atproto_did("not a did")

    @test ensure_atproto_did("did:plc:ewvi7nx4oun5hl7s6yqkgcto") == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
    @test ensure_atproto_did("did:web:example.com") == "did:web:example.com"
    @test_throws ATProtoDidError ensure_atproto_did("did:web:example.com%3A8443")
    @test_throws ATProtoDidError ensure_atproto_did("did:key:zabc")
end
