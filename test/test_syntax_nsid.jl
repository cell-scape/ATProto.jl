using Test
using ATProto
using ATProto.Syntax

@testset "NSID" begin
    @testset "valid" begin
        for s in (
            "com.example.foo",
            "a.b.c",
            "a0.b.c",
            "a.b-c.d",
            "app.bsky.feed.post",
            "com.example.track3",
            "a.b.c.d.e.f.g",
        )
            @test is_valid_nsid(s)
            @test ensure_valid_nsid(s) == s
            @test parse_nsid(s) == String.(split(s, "."))
        end
    end

    @testset "invalid" begin
        for s in (
            "com.example",      # two parts only
            "com",              # one part
            ".com.foo",         # leading dot (empty part)
            "com..foo",         # empty middle part
            "-a.b.c",           # leading hyphen
            "a.b.c-",           # name ending in hyphen
            "a-.b.c",           # trailing hyphen in label
            "com.example.0abc", # name starts with digit
            "com.example.a-b",  # name contains hyphen
            "com.example." * "a"^64, # >63-char name part
            "0abc.b.c",         # first part starts with digit
            "a b.c.d",          # whitespace
            "a_b.c.d",          # underscore
        )
            @test !is_valid_nsid(s)
            @test_throws InvalidNsidError ensure_valid_nsid(s)
        end
        # too long (317 chars max): five 63-char labels + name = 321 chars
        too_long = join(("a"^63 for _ in 1:5), ".") * ".z"
        @test length(too_long) > 317
        @test !is_valid_nsid(too_long)
        @test_throws InvalidNsidError ensure_valid_nsid(too_long)
    end

    @testset "errors" begin
        err = try
            parse_nsid("com.example"); nothing
        catch e
            e
        end
        @test err isa InvalidNsidError
        @test err.msg == "NSID needs at least three parts"

        err = try
            parse_nsid("com.example.0x"); nothing
        catch e
            e
        end
        @test err.msg == "NSID name part must be only letters and digits (and no leading digit)"
    end

    @testset "type" begin
        nsid = NSID("com.example.status")
        @test nsid.segments == ["com", "example", "status"]
        @test nsid_authority(nsid) == "example.com"
        @test nsid_name(nsid) == "status"
        @test string(nsid) == "com.example.status"
        @test nsid == "com.example.status"
        @test "com.example.status" == nsid
        @test NSID(nsid) === nsid
        @test hash(NSID("a.b.c")) == hash(NSID("a.b.c"))

        @test make_nsid("example.com", "status") == NSID("com.example.status")
        @test make_nsid("sub.example.com", "thing") == NSID("com.example.sub.thing")
        @test nsid_authority("app.bsky.feed.post") == "feed.bsky.app"
        @test nsid_authority("com.example.status") == "example.com"
        @test nsid_name("app.bsky.feed.post") == "post"
        @test_throws InvalidNsidError NSID("notanid")
    end
end
