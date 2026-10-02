using Test
using ATProto
using ATProto.Syntax

@testset "AtURI" begin
    @testset "parse" begin
        uri = AtURI("at://did:plc:abc123/app.bsky.feed.post/3jx2h5l2b1c2p")
        @test host(uri) == "did:plc:abc123"
        @test pathname(uri) == "/app.bsky.feed.post/3jx2h5l2b1c2p"
        @test collection(uri) == "app.bsky.feed.post"
        @test rkey(uri) == "3jx2h5l2b1c2p"
        @test collection_safe(uri) == "app.bsky.feed.post"
        @test rkey_safe(uri) == "3jx2h5l2b1c2p"
        @test origin(uri) == "at://did:plc:abc123"
        @test did(uri) == "did:plc:abc123"

        # scheme is optional when parsing
        uri2 = AtURI("did:plc:abc123/app.bsky.feed.post/xyz")
        @test host(uri2) == "did:plc:abc123"

        # handles as host
        uri3 = AtURI("at://handle.example/com.example.status/3jx2c2a")
        @test host(uri3) == "handle.example"
        @test_throws InvalidDidError did(uri3)

        # no path
        uri4 = AtURI("at://did:plc:abc123")
        @test pathname(uri4) == ""
        @test collection(uri4) == ""
        @test rkey(uri4) == ""

        # query parameters
        uri5 = AtURI("at://did:plc:abc123/com.example.record?key=value+with+spaces&k2=v2")
        @test uri5.search_params == ["key" => "value with spaces", "k2" => "v2"]
        @test query(uri5) == "key=value+with+spaces&k2=v2"

        # percent-encoding round trip
        uri6 = AtURI("at://did:plc:abc123/r?a=%2Fb%20c")
        @test uri6.search_params == ["a" => "/b c"]
        @test query(uri6) == "a=%2Fb+c"

        # fragment
        uri7 = AtURI("at://did:plc:abc123/com.ex.rec/rkey#frag")
        @test fragment(uri7) == "#frag"

        # safe accessors throw on missing/invalid parts
        @test_throws InvalidNsidError collection_safe(uri4)
        @test_throws InvalidRecordKeyError rkey_safe(AtURI("at://did:plc:abc123/com.ex.rec"))
    end

    @testset "invalid" begin
        for s in ("at://", "http://example.com", "at://did:plc:", "at://alice",
                  "at://did:plc:abc/a b", "ftp://x.y", "")
            @test_throws ATProtoSyntaxError AtURI(s)
        end
    end

    @testset "make and serialize" begin
        uri = at_uri("did:plc:abc123", "app.bsky.feed.post", "3jx2h5l2b1c2p")
        @test string(uri) == "at://did:plc:abc123/app.bsky.feed.post/3jx2h5l2b1c2p"
        @test uri == "at://did:plc:abc123/app.bsky.feed.post/3jx2h5l2b1c2p"

        @test string(at_uri("did:plc:abc123")) == "at://did:plc:abc123"
        @test string(at_uri("did:plc:abc123", "com.ex.rec")) ==
              "at://did:plc:abc123/com.ex.rec"

        # round-trip
        s = "at://did:plc:abc/app.bsky.feed.post/3jx2h5l2b1c2p?foo=bar#frag"
        @test string(AtURI(s)) == s

        # handle hosts are preserved as written (not lower-cased), like the TS
        @test string(AtURI("at://Handle.Example/com.ex.rec/rk")) ==
              "at://Handle.Example/com.ex.rec/rk"
    end

    @testset "base resolution" begin
        base = "at://did:plc:abc123/app.bsky.feed.post"
        uri = AtURI("/com.example.other/3jx2c2a"; base = base)
        @test host(uri) == "did:plc:abc123"
        @test pathname(uri) == "/com.example.other/3jx2c2a"

        uri2 = AtURI("?q=1#top"; base = AtURI("at://did:plc:abc123/com.ex.rec/rk"))
        @test host(uri2) == "did:plc:abc123"
        @test pathname(uri2) == ""
        @test uri2.search_params == ["q" => "1"]
        @test fragment(uri2) == "#top"
    end

    @testset "equality" begin
        @test AtURI("at://did:plc:abc/a.b.c/x") == AtURI("did:plc:abc/a.b.c/x")
        @test hash(AtURI("at://did:plc:abc/a.b.c/x")) == hash(AtURI("did:plc:abc/a.b.c/x"))
        @test AtURI("at://did:plc:abc/a.b.c/x") != AtURI("at://did:plc:abc/a.b.c/y")
    end
end
