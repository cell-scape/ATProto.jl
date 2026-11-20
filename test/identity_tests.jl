using ATProto
using ATProto.Identity
using ATProto.Syntax
using HTTP
using JSON
using Test

const Sockets = HTTP.Sockets

@testset "Identity Resolution (DID & Handle)" begin
    sample_did = did"did:plc:z72i7hdynmk6r22z27h6tvur"
    sample_doc_dict = Dict(
        "@context" => ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/multikey/v1"],
        "id" => String(sample_did),
        "alsoKnownAs" => ["https://example.com", "at://Bsky.App"],
        "verificationMethod" => [
            Dict(
                "id" => "$(sample_did)#atproto",
                "type" => "Multikey",
                "controller" => String(sample_did),
                "publicKeyMultibase" => "zQ3shXjHeiBuRCKmM36cuYnm7YNozMjVwCfzY1qC9oQ2x6u5b",
            ),
        ],
        "service" => [
            Dict(
                "id" => "#atproto_pds",
                "type" => "AtprotoPersonalDataServer",
                "serviceEndpoint" => "https://bsky.social/",
            ),
        ],
    )

    @testset "DIDDocument parsing & helpers" begin
        doc = parse_did_document(JSON.json(sample_doc_dict))
        @test doc.id == sample_did
        @test atproto_handle(doc) == handle"bsky.app"
        @test pds_endpoint(doc) == "https://bsky.social"
        sk = signing_key(doc)
        @test sk isa DIDVerificationMethod
        @test sk.type == "Multikey"
        @test startswith(sk.publicKeyMultibase, "zQ3sh")
        @test occursin("bsky.app", sprint(show, doc))

        @test_throws IdentityError parse_did_document("not-json")
        @test_throws IdentityError parse_did_document(Dict("id" => "not-a-did"))
    end

    @testset "did:web URL rules" begin
        @test did_web_url(did"did:web:example.com") == "https://example.com/.well-known/did.json"
        @test did_web_url("did:web:localhost%3A3000") == "http://localhost:3000/.well-known/did.json"
        @test did_web_url("did:web:127.0.0.1%3a8080") == "http://127.0.0.1:8080/.well-known/did.json"
        @test_throws IdentityError did_web_url(did"did:web:example.com:user:alice")
        @test_throws IdentityError did_web_url(sample_did)
    end

    @testset "resolve_did (did:plc, did:web, mismatch & caching)" begin
        calls = Ref(0)
        transport = function (url, headers; timeout)
            calls[] += 1
            if url == "https://plc.directory/$(sample_did)"
                return HTTP.Response(200, ["Content-Type" => "application/json"]; body = JSON.json(sample_doc_dict))
            elseif url == "https://alice.example/.well-known/did.json"
                return HTTP.Response(200, ["Content-Type" => "application/json"]; body = JSON.json(Dict(
                    "id" => "did:web:alice.example",
                    "alsoKnownAs" => ["at://alice.example"],
                )))
            elseif url == "https://plc.directory/did:plc:mismatch123"
                # Spoofed document returning wrong id
                return HTTP.Response(200, ["Content-Type" => "application/json"]; body = JSON.json(sample_doc_dict))
            end
            return HTTP.Response(404)
        end

        resolver = IdentityResolver(http_transport = transport, cache_ttl = 60.0)
        doc1 = resolve_did(resolver, sample_did)
        doc2 = resolve_did(resolver, sample_did)
        @test doc1 == doc2
        @test calls[] == 1 # served from TTL cache

        # force_refresh bypasses cache
        resolve_did(resolver, sample_did; force_refresh = true)
        @test calls[] == 2

        clear_cache!(resolver)
        resolve_did(resolver, sample_did)
        @test calls[] == 3

        # did:web
        web_doc = resolve_did(resolver, did"did:web:alice.example")
        @test web_doc.id == did"did:web:alice.example"
        @test atproto_handle(web_doc) == handle"alice.example"

        # Mismatched DID id throws IdentityError
        @test_throws IdentityError resolve_did(resolver, "did:plc:mismatch123")
        # Unsupported method throws IdentityError
        @test_throws IdentityError resolve_did(resolver, "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
    end

    @testset "resolve_handle (DNS TXT via DoH, HTTPS well-known & ambiguity rejection)" begin
        transport = function (url, headers; timeout)
            if occursin("dns.google/resolve", url) && occursin("_atproto.dns.example", url)
                return HTTP.Response(200, ["Content-Type" => "application/dns-json"]; body = JSON.json(Dict(
                    "Status" => 0,
                    "Answer" => [
                        Dict("name" => "_atproto.dns.example.", "type" => 16, "data" => "\"did=$(sample_did)\""),
                    ],
                )))
            elseif occursin("dns.google/resolve", url) && occursin("_atproto.ambig.example", url)
                return HTTP.Response(200, ["Content-Type" => "application/dns-json"]; body = JSON.json(Dict(
                    "Status" => 0,
                    "Answer" => [
                        Dict("type" => 16, "data" => "\"did=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa\""),
                        Dict("type" => 16, "data" => "\"did=did:plc:bbbbbbbbbbbbbbbbbbbbbbbb\""),
                    ],
                )))
            elseif url == "https://web.example/.well-known/atproto-did"
                return HTTP.Response(200, ["Content-Type" => "text/plain"]; body = "$(sample_did)\n")
            end
            return HTTP.Response(404)
        end

        resolver = IdentityResolver(http_transport = transport)

        @test resolve_handle(resolver, handle"dns.example"; method = :dns) == sample_did
        @test resolve_handle(resolver, "dns.example") == sample_did
        @test resolve_handle(resolver, "web.example"; method = :https) == sample_did
        @test resolve_handle(resolver, "web.example") == sample_did # falls back from DNS to HTTPS
        @test resolve_handle(resolver, "ambig.example"; method = :dns) === nothing
        @test resolve_handle(resolver, "missing.example") === nothing
        @test_throws ArgumentError resolve_handle(resolver, "dns.example"; method = :bogus)

        # Custom dns_resolver callback
        custom = IdentityResolver(
            dns_resolver = dom -> dom == "_atproto.custom.example" ? ["did=$(sample_did)"] : String[],
            http_transport = transport,
        )
        @test resolve_handle(custom, "custom.example"; method = :dns) == sample_did
    end

    @testset "Bidirectional handle verification & spoof detection" begin
        transport = function (url, headers; timeout)
            if url == "https://plc.directory/$(sample_did)"
                return HTTP.Response(200, ["Content-Type" => "application/json"]; body = JSON.json(sample_doc_dict))
            elseif url == "https://bsky.app/.well-known/atproto-did"
                return HTTP.Response(200, ["Content-Type" => "text/plain"]; body = String(sample_did))
            elseif url == "https://spoof.example/.well-known/atproto-did"
                # Points to sample_did, but sample_did's DID doc claims at://bsky.app, NOT spoof.example!
                return HTTP.Response(200, ["Content-Type" => "text/plain"]; body = String(sample_did))
            end
            return HTTP.Response(404)
        end

        resolver = IdentityResolver(dns_resolver = _ -> String[], http_transport = transport)

        @test verify_handle(resolver, handle"bsky.app", sample_did) == true
        @test verify_handle(resolver, handle"spoof.example", sample_did) == false

        id_by_handle = resolve_identity(resolver, "bsky.app")
        @test id_by_handle.did == sample_did
        @test id_by_handle.handle == handle"bsky.app"
        @test id_by_handle.handle_verified == true
        @test id_by_handle.pds == "https://bsky.social"
        @test !isnothing(id_by_handle.signing_key)
        @test occursin("verified=true", sprint(show, id_by_handle))

        id_by_did = resolve_identity(resolver, sample_did)
        @test id_by_did.handle == handle"bsky.app"
        @test id_by_did.handle_verified == true

        # Spoofed handle resolves the DID doc, but handle_verified MUST be false!
        spoof_id = resolve_identity(resolver, "spoof.example")
        @test spoof_id.did == sample_did
        @test spoof_id.handle_verified == false
    end

    @testset "Loopback HTTP did:plc & did:web resolution" begin
        server = HTTP.serve!(Sockets.localhost, 0) do req::HTTP.Request
            if req.target == "/$(sample_did)"
                return HTTP.Response(200, ["Content-Type" => "application/json"]; body = JSON.json(sample_doc_dict))
            elseif req.target == "/.well-known/did.json"
                host = HTTP.header(req, "Host", "")
                did_str = "did:web:" * replace(host, ":" => "%3A")
                return HTTP.Response(200, ["Content-Type" => "application/json"]; body = JSON.json(Dict(
                    "id" => did_str,
                    "alsoKnownAs" => ["at://loopback.test"],
                )))
            end
            return HTTP.Response(404)
        end

        try
            _, port = Sockets.getsockname(server.listener.server)
            resolver = IdentityResolver(plc_url = "http://127.0.0.1:$port")
            doc = resolve_did(resolver, sample_did)
            @test doc.id == sample_did
            @test atproto_handle(doc) == handle"bsky.app"

            web_did = DID("did:web:127.0.0.1%3A$port")
            wdoc = resolve_did(resolver, web_did)
            @test wdoc.id == web_did
            @test atproto_handle(wdoc) == handle"loopback.test"
        finally
            close(server)
        end
    end
end
