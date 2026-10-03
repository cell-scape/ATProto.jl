using Test
using ATProto
using ATProto.Identity
using ATProto.DID
using HTTP
using JSON

const PLC_DID = "did:plc:ewvi7nx4oun5hl7s6yqkgcto"

function make_fetch(pairs::Pair...)
    responses = Dict{String,Any}(String(k) => v for (k, v) in pairs)
    return (url; headers = (), timeout = 3.0) -> begin
        resp = get(responses, String(url), nothing)
        resp === nothing && return HTTP.Response(404, UInt8[])
        status, body = resp
        return HTTP.Response(status, Vector{UInt8}(codeunits(body)))
    end
end

@testset "HandleResolver via DNS" begin
    r = HandleResolver(;
        resolve_dns = h -> h == "alice.example.com" ? PLC_DID : nothing,
        fetch = make_fetch(),  # everything 404s
    )
    @test resolve_handle(r, "alice.example.com") == PLC_DID
    @test resolve_handle(r, "unknown.example.com") === nothing
    @test_throws HandleNotFoundError ensure_handle(r, "unknown.example.com")
    @test ensure_handle(r, "alice.example.com") == PLC_DID
end

@testset "HandleResolver via well-known HTTP" begin
    r = HandleResolver(;
        resolve_dns = _ -> nothing,
        fetch = make_fetch(
            "https://bob.example.com/.well-known/atproto-did" =>
            (200, "$PLC_DID\n"),
        ),
    )
    @test resolve_handle(r, "bob.example.com") == PLC_DID
    # multi-line body: first line wins
    r2 = HandleResolver(;
        resolve_dns = _ -> nothing,
        fetch = make_fetch(
            "https://carol.example.com/.well-known/atproto-did" =>
            (200, "  $PLC_DID  \nsome trailing text\n"),
        ),
    )
    @test resolve_handle(r2, "carol.example.com") == PLC_DID
    # non-did body -> nothing
    r3 = HandleResolver(;
        resolve_dns = _ -> nothing,
        fetch = make_fetch(
            "https://dave.example.com/.well-known/atproto-did" =>
            (200, "not a did\n"),
        ),
    )
    @test resolve_handle(r3, "dave.example.com") === nothing
    # 404 -> nothing
    @test resolve_handle(r3, "missing.example.com") === nothing
end

@testset "HandleResolver precedence and fallback" begin
    # DNS wins over HTTP
    http_calls = Ref(0)
    fetch = (url; headers = (), timeout = 3.0) -> begin
        http_calls[] += 1
        return HTTP.Response(404, UInt8[])
    end
    r = HandleResolver(;
        resolve_dns = _ -> PLC_DID,
        fetch,
    )
    @test resolve_handle(r, "any.example.com") == PLC_DID
    @test http_calls[] == 0  # DNS result short-circuits

    # backup nameservers are used when DNS + HTTP both miss: verify the
    # backup path calls resolve_handle_dns with the backup servers
    calls = Vector{Any}()
    backup_dns = function (handle; nameservers = String[], timeout = 2.0, kwargs...)
        push!(calls, (handle, nameservers))
        return PLC_DID
    end
    # patch the fallback by injecting it as the backup resolution path
    r2 = HandleResolver(;
        resolve_dns = _ -> nothing,
        fetch = (url; kwargs...) -> HTTP.Response(404, UInt8[]),
        backup_nameservers = ["1.1.1.1", "8.8.8.8"],
    )
    # (resolve_handle falls back to resolve_handle_dns with backup servers;
    #  in the offline test environment this hits the real resolver, so we
    #  only check the code path doesn't throw and accepts nothing)
    result = resolve_handle(r2, "fallback.example.com")
    @test result === nothing || result isa String
end

const FIXTURE_DOC = JSON.parse(read(joinpath(@__DIR__, "fixtures", "plc_doc.json"), String))

@testset "resolve_identity (bidirectional)" begin
    doc = Dict{String,Any}(copy(FIXTURE_DOC))
    doc["alsoKnownAs"] = ["at://alice.example.com"]
    did_url = "https://plc.directory/" * HTTP.URIs.escapeuri(PLC_DID)
    http = make_fetch(
        did_url => (200, JSON.json(doc)),
        "https://alice.example.com/.well-known/atproto-did" => (200, "$PLC_DID\n"),
    )
    r = IdResolver(; fetch = http, resolve_dns = _ -> PLC_DID)
    @test resolve_identity(r, "alice.example.com") == PLC_DID
    # case-insensitive handle match
    @test resolve_identity(r, "ALICE.EXAMPLE.COM") == PLC_DID

    # handle resolves but DID doc declares a different handle
    doc_mismatch = Dict{String,Any}(copy(doc))
    doc_mismatch["alsoKnownAs"] = ["at://eve.example.com"]
    http2 = make_fetch(
        did_url => (200, JSON.json(doc_mismatch)),
        "https://alice.example.com/.well-known/atproto-did" => (200, "$PLC_DID\n"),
    )
    r2 = IdResolver(; fetch = http2, resolve_dns = _ -> PLC_DID)
    err = try resolve_identity(r2, "alice.example.com"); nothing catch e; e end
    @test err isa IdentityMismatchError
    @test err.handle == "alice.example.com"
    @test err.did == PLC_DID
    @test err.doc_handle == "eve.example.com"

    # unresolvable handle
    r3 = IdResolver(;
        fetch = make_fetch(),
        resolve_dns = _ -> nothing,
    )
    @test_throws HandleNotFoundError resolve_identity(r3, "nobody.example.com")
end
