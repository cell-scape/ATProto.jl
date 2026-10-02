using Test
using ATProto
using ATProto.Syntax
using Dates

@testset "DID" begin
    @testset "valid" begin
        for s in (
            "did:plc:pojqtcdfztwdj4husb4oecoq",
            "did:web:example.com",
            "did:web:example.com:path",
            "did:plc:abc123",
            "did:plc:abc123:optional",
            "did:key:zQ3sHonoPpzK5uSG7yqCd5ZU8bW3brrKaxwJ3uhD4KgZjnTrue",
            "did:example:12UASJ3h3h3KKj5ZfZ4aPtFmcY3YQjLzZDLJJ3h3h3KKj5ZfZ4aPtFmcY3YQjLzZDLJJ3h3h3KKj5ZfZ4aPtFmcY3YQjLzZDLJJ",
        )
            @test is_valid_did(s)
            @test ensure_valid_did(s) == s
            @test ATProto.did_method(s) in ("plc", "web", "key", "example")
        end
        @test ATProto.did_method("did:web:example.com") == "web"
        @test ATProto.did_method("did:plc:abc123") == "plc"
    end

    @testset "invalid" begin
        for s in (
            "did:plc:",                # ends with ':'
            "DID:plc:abc123",          # wrong case prefix
            "did:PLC:abc123",          # method must be lower-case
            "did::abc123",             # empty method
            "did:plc",                 # no method-specific content
            "did:plc:abc%",            # can not end with '%'
            "did:plc:abc/123",         # disallowed character
            "did:plc:abc def",         # whitespace
            "did:plc:abc def",         # whitespace
            "plc:abc123",              # missing prefix
            "",                        # empty
            "did:plc:é",               # non-ASCII
        )
            @test !is_valid_did(s)
            @test_throws InvalidDidError ensure_valid_did(s)
        end
        # too long (2048 chars max)
        long_did = "did:plc:" * "a"^2048
        @test !is_valid_did(long_did)
        @test_throws InvalidDidError ensure_valid_did(long_did)
    end
end

@testset "Handle" begin
    @testset "valid" begin
        for s in (
            "alice.bsky.social",
            "joyce.jacobs.example",
            "9times.online",           # leading digit in first label is OK
            "xn--fiqs8s.example",      # punycode (ASCII)
            "a-c.b.com",
            "a.co",
            "ALICE.BSKY.SOCIAL",       # case-insensitive syntax
            "a1.2b.c3-d",
            "test.test",               # .test is allowed at syntax level
        )
            @test is_valid_handle(s)
            @test ensure_valid_handle(s) == s
        end
    end

    @testset "invalid" begin
        for s in (
            "alice.example.",   # trailing dot
            ".alice.example",   # leading dot
            "alice..example",   # empty middle label
            "-alice.example",   # leading hyphen
            "alice-.example",   # trailing hyphen
            "alice.123",        # TLD starts with digit
            "alice",            # needs at least two parts
            "a_b.example",      # underscore not allowed
            "a b.example",      # whitespace
            "joão.example",     # non-ASCII
        )
            @test !is_valid_handle(s)
            @test_throws InvalidHandleError ensure_valid_handle(s)
        end
        @test !is_valid_handle("a"^254 * ".com")  # 253 chars max
        @test !is_valid_handle("a"^64 * ".com")   # 63 chars per label max
        @test_throws InvalidHandleError ensure_valid_handle("a"^64 * ".com")
    end

    @testset "normalize" begin
        @test normalize_handle("ALICE.Bsky.Social") == "alice.bsky.social"
        @test normalize_and_ensure_valid_handle("ALICE.BSKY.SOCIAL") == "alice.bsky.social"
        @test_throws InvalidHandleError normalize_and_ensure_valid_handle("bad handle.example")
    end

    @testset "TLD policy" begin
        for tld in (".local", ".arpa", ".invalid", ".localhost", ".internal", ".example", ".alt", ".onion")
            @test !is_valid_tld("foo" * tld)
        end
        @test is_valid_tld("foo.test")
        @test is_valid_tld("alice.bsky.social")
        @test ATProto.INVALID_HANDLE == "handle.invalid"
    end
end

@testset "AtIdentifier" begin
    @test is_did_identifier("did:plc:abc123")
    @test !is_did_identifier("alice.bsky.social")
    @test is_handle_identifier("alice.bsky.social")
    @test !is_handle_identifier("did:plc:abc123")

    @test is_valid_at_identifier("did:plc:pojqtcdfztwdj4husb4oecoq")
    @test is_valid_at_identifier("alice.bsky.social")
    for s in ("alice", "did:plc:", "http://example.com", "")
        @test !is_valid_at_identifier(s)
        @test_throws InvalidAtIdentifierError ensure_valid_at_identifier(s)
    end
end

@testset "RecordKey" begin
    for s in (
        "3jx2h5l2b1c2p",
        "self",
        "a.b",
        "a:b",
        "a-b",
        "a_b",
        "a~b",
        "a" ^ 1,
        "3jzfcijpj2z2a",
    )
        @test is_valid_record_key(s)
        @test ensure_valid_record_key(s) == s
    end
    for s in ("", ".", "..", "a/b", "a b", "a#b", "a?b", "a%b", "a+b", "a=b")
        @test !is_valid_record_key(s)
        @test_throws InvalidRecordKeyError ensure_valid_record_key(s)
    end
    @test !is_valid_record_key("a"^513)
    @test is_valid_record_key("a"^512)
    @test_throws InvalidRecordKeyError ensure_valid_record_key("a"^513)
end

@testset "TID" begin
    @test is_valid_tid("3jzfcijpj2z2a")
    @test is_valid_tid("3iza3hxjle4d2")
    @test is_valid_tid("2222222222222")
    @test ensure_valid_tid("3jzfcijpj2z2a") == "3jzfcijpj2z2a"

    for s in ("zzzzzzzzzzzzz",   # high bit set (first char not in 2..j)
              "222222222222",    # 12 chars
              "22222222222222",  # 14 chars
              "3jzfcijpj2z20",   # '0' not in alphabet
              "3jzfcijpj2z28",   # '8' not in alphabet
              "3JZFCIJPJ2Z2A",   # upper case not allowed
              "")
        @test !is_valid_tid(s)
        @test_throws InvalidTidError ensure_valid_tid(s)
    end
    @test is_valid_tid("3jzfcijpj2z2k")  # any alphabet char after the first

    @testset "codec" begin
        @test format_tid(UInt64(0)) == "2222222222222"
        @test parse_tid("2222222222222") == UInt64(0)
        # top bit is masked on encode (63 one-bits -> 'b' + 'z'*12)
        @test format_tid(typemax(UInt64) >> 1) == "bzzzzzzzzzzzz"
        @test parse_tid("bzzzzzzzzzzzz") == typemax(UInt64) >> 1
        @test format_tid(typemax(UInt64)) == "bzzzzzzzzzzzz"  # top bit masked
        # round-trip (for values with the top bit unset)
        for u in (UInt64(0), UInt64(1), UInt64(0x3ff), UInt64(1234567890), typemax(UInt64) >> 1)
            @test parse_tid(format_tid(u)) == u
            @test UInt64(TID(u)) == u
        end
        @test string(TID("3jzfcijpj2z2a")) == "3jzfcijpj2z2a"
        @test TID("3jzfcijpj2z2a") == "3jzfcijpj2z2a"
    end

    @testset "timestamp" begin
        # 53-bit microseconds + 10-bit clockid
        tid = TID(DateTime(2023, 6, 1, 12, 0, 0); clockid = 5)
        @test tid_timestamp(tid) == DateTime(2023, 6, 1, 12, 0, 0)
        @test tid_clockid(tid) == 5
        @test tid_clockid("2222222222222") == 0
        now_tid = TID()
        @test abs(tid_timestamp(now_tid) - Dates.now(Dates.UTC)) < Second(5)
        # sortability: string ordering matches time ordering
        @test isless(TID(UInt64(1000)), TID(UInt64(2000)))
    end
end
