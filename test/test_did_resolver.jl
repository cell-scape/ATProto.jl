using Test
using ATProto
using ATProto.DID
using ATProto.Crypto
using HTTP
using JSON

include("fixtures/reference_fixtures.jl")
const FIXTURE_DOC = JSON.parse(read(joinpath(@__DIR__, "fixtures", "plc_doc.json"), String))

const PLC_DID = "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
const PLC_URL = "https://plc.directory/" * HTTP.URIs.escapeuri(PLC_DID)

# --- canned transport -----------------------------------------------------------

mutable struct CountingFetch
    responses::Dict{String,Any}   # url => (status, body) or Exception
    calls::Vector{String}
end

function (f::CountingFetch)(url::AbstractString; headers = (), timeout = 3.0)
    push!(f.calls, String(url))
    resp = get(f.responses, String(url), nothing)
    resp === nothing && return HTTP.Response(404, UInt8[])
    resp isa Exception && throw(resp)
    status, body = resp
    return HTTP.Response(status, Vector{UInt8}(codeunits(body)))
end

function make_fetch(pairs::Pair...)
    return CountingFetch(Dict{String,Any}(String(k) => v for (k, v) in pairs), String[])
end

# --- tests -------------------------------------------------------------------------

@testset "PlcResolver" begin
    doc_json = JSON.json(FIXTURE_DOC)
    fetch = make_fetch(
        PLC_URL => (200, doc_json),
    )
    r = DidResolver(; fetch)
    doc = resolve_document(r, PLC_DID)
    @test doc !== nothing
    @test get_pds_endpoint(doc) == FIXTURE_DOC["service"][1]["serviceEndpoint"]

    # not found -> nothing / throws on ensure
    fetch404 = make_fetch()
    r404 = DidResolver(; fetch = fetch404)
    @test resolve_document(r404, PLC_DID; force_refresh = true) === nothing
    @test_throws DidNotFoundError ensure_resolve(r404, PLC_DID)

    # id mismatch -> PoorlyFormattedDidDocumentError
    bad_doc = Dict{String,Any}(copy(FIXTURE_DOC))
    bad_doc["id"] = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    fetchbad = make_fetch(PLC_URL => (200, JSON.json(bad_doc)))
    rbad = DidResolver(; fetch = fetchbad)
    @test_throws ATProtoDidError resolve_document(rbad, PLC_DID)

    # unsupported method
    @test_throws UnsupportedDidMethodError resolve_document(r, "did:key:zabc")

    # server error
    fetch500 = make_fetch(PLC_URL => (500, "oops"))
    r500 = DidResolver(; fetch = fetch500)
    @test_throws ErrorException resolve_document(r500, PLC_DID)
end

@testset "WebResolver" begin
    web_doc = Dict{String,Any}(copy(FIXTURE_DOC)); web_doc["id"] = "did:web:example.com"
    localhost_doc = Dict{String,Any}(copy(FIXTURE_DOC)); localhost_doc["id"] = "did:web:localhost"
    fetch = make_fetch(
        "https://example.com/.well-known/did.json" => (200, JSON.json(web_doc)),
        "http://localhost/.well-known/did.json" => (200, JSON.json(localhost_doc)),
    )
    r = DidResolver(; fetch)

    doc = resolve_document(r, "did:web:example.com")
    @test doc !== nothing
    @test doc.id == "did:web:example.com"

    # localhost uses http://
    doc2 = resolve_document(r, "did:web:localhost")
    @test doc2 !== nothing

    # any non-200 -> nothing
    @test resolve_document(r, "did:web:missing.example") === nothing
end

@testset "cache" begin
    doc_json = JSON.json(FIXTURE_DOC)
    t = Ref(1000.0)
    fetch = make_fetch(PLC_URL => (200, doc_json))
    cache = DidMemoryCache(; stale_ttl = 100.0, max_ttl = 1000.0, now = () -> t[])
    r = DidResolver(; fetch, cache)

    # first resolve hits the network
    @test resolve_document(r, PLC_DID) !== nothing
    @test length(fetch.calls) == 1

    # fresh cache hit: no network
    resolve_document(r, PLC_DID)
    @test length(fetch.calls) == 1

    # stale entry (> stale_ttl): served without blocking on refresh
    t[] += 200.0
    resolve_document(r, PLC_DID)
    @test length(fetch.calls) == 1

    # expired entry (> max_ttl): re-fetched
    t[] += 1000.0
    @test resolve_document(r, PLC_DID) !== nothing
    @test length(fetch.calls) == 2

    # force_refresh bypasses cache
    resolve_document(r, PLC_DID; force_refresh = true)
    @test length(fetch.calls) == 3

    # 404 clears the entry
    fetch404 = make_fetch()
    cache2 = DidMemoryCache(; now = () -> t[])
    r404 = DidResolver(; fetch = fetch404, cache = cache2)
    cache_did!(cache2, PLC_DID, parse_did_document(PLC_DID, FIXTURE_DOC))
    @test resolve_document(r404, PLC_DID; force_refresh = true) === nothing
    @test check_cache(cache2, PLC_DID) === nothing
end

@testset "atproto data + key resolution" begin
    fetch = make_fetch(
        PLC_URL => (200, JSON.json(FIXTURE_DOC)),
    )
    r = DidResolver(; fetch)

    data = resolve_atproto_data(r, PLC_DID)
    @test data.did == PLC_DID
    @test data.handle == FIXTURE_DOC["alsoKnownAs"][1][6:end]
    @test data.pds == FIXTURE_DOC["service"][1]["serviceEndpoint"]

    # signing key resolution + signature verification round trip
    key = import_key(Secp256k1Key, FIXTURES.keys[2].priv_hex)
    doc = Dict{String,Any}(copy(FIXTURE_DOC))
    doc["verificationMethod"] = [Dict(
        "id" => "$PLC_DID#atproto",
        "type" => "Multikey",
        "controller" => PLC_DID,
        "publicKeyMultibase" => did_key(key)[length("did:key:")+1:end],
    )]
    fetch2 = make_fetch(PLC_URL => (200, JSON.json(doc)))
    r2 = DidResolver(; fetch = fetch2)
    @test resolve_atproto_key(r2, PLC_DID) == did_key(key)

    msg = codeunits("verify me")
    sig = sign_message(key, msg)
    @test verify_signature(r2, PLC_DID, msg, sig)
    @test !verify_signature(r2, PLC_DID, codeunits("other"), sig)

    # did:key resolves to itself
    @test resolve_atproto_key(r, "did:key:zabc") == "did:key:zabc"
end
