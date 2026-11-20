using ATProto
using ATProto.Syntax
using Dates
using JSON
using Test

# Test vectors modeled after the official bluesky-social/atproto-interop-tests syntax suite.

@testset "Handles" begin
    valid_handles = [
        "jay.bsky.social",
        "8.cn",
        "name.t--t",
        "XX.LCS.MIT.EDU",
        "a.co",
        "a.a",
        "a0.b1",
        "a-b.c-d",
        "123.com",
        "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z",
        "xn--notarealidn.com",
        "example.com",
        "handle.invalid",
        "a" * "b"^62 * ".com",
        ("a"^63 * ".")^3 * "a"^61, # exact 253 bytes
    ]

    invalid_handles = [
        "",
        "no-tld",
        "example.com.",
        ".example.com",
        "example..com",
        "a..b.com",
        "a.-b.com",
        "a.-.b.com",
        "-example.com",
        "example-.com",
        "example.com-",
        "example.-com",
        "example.123",
        "example.1com",
        "123.456",
        "a"^64 * ".com",
        "a." * "b"^64,
        ("a"^63 * ".")^3 * "a"^62, # 254 bytes
        "foo bar.com",
        "foo_bar.com",
        "foo@bar.com",
        "foo/bar.com",
        "α.com",
        "éxample.com",
        "example.cöm",
        "example.com\n",
        "example.com\0",
        "did:plc:z72i7hdynmk6r22z27h6tvur",
    ]

    for h in valid_handles
        @test is_valid_handle(h)
        @test is_valid_handle(SubString(h))
        @test is_valid_handle_regex(h)
        @test ensure_valid_handle(h) === nothing
        @test ensure_valid_handle_regex(h) === nothing
        parsed = tryparse(Handle, h)
        @test parsed isa Handle
        @test String(parsed) == lowercase(h)
        @test parse(Handle, h) == parsed
    end

    for h in invalid_handles
        @test !is_valid_handle(h)
        @test !is_valid_handle_regex(h)
        @test_throws SyntaxError ensure_valid_handle(h)
        @test_throws SyntaxError ensure_valid_handle_regex(h)
        @test tryparse(Handle, h) === nothing
        @test_throws SyntaxError Handle(h)
    end

    # Normalization & equality
    @test normalize_handle("Example.COM") == "example.com"
    @test normalize_and_ensure_valid_handle("Example.COM") == "example.com"
    @test_throws SyntaxError normalize_and_ensure_valid_handle("no-tld")
    @test Handle("Bsky.App") == Handle("bsky.app") == handle"bsky.app"
    @test hash(Handle("Bsky.App")) == hash(handle"bsky.app")
    @test string(handle"Bsky.App") == "bsky.app"

    # Disallowed TLDs (including case-insensitivity & previously reversed endswith bug)
    @test is_valid_tld("example.com")
    @test is_valid_tld("bsky.app")
    @test !is_valid_tld("handle.invalid")
    @test !is_valid_tld("HANDLE.INVALID")
    @test !is_valid_tld("foo.local")
    @test !is_valid_tld("foo.LOCAL")
    @test !is_valid_tld("foo.onion")
    @test !is_valid_tld("foo.localhost")
    @test is_valid_tld("invalid") # bare word without leading '.'

    # Character helpers (ASCII only)
    @test valid_handle_char('a')
    @test valid_handle_char('9')
    @test valid_handle_char('-')
    @test valid_handle_char('.')
    @test !valid_handle_char('α')
    @test !valid_handle_char('#')
    @test valid_handle_chars("example.com")
    @test valid_handle_chars("no-tld")
    @test !valid_handle_chars("α.com")
    @test !valid_handle_chars("example.com\n")

    # Zero-allocation validation check
    s = "jay.bsky.social"
    @test (@allocated is_valid_handle(s)) == 0
end

@testset "DIDs" begin
    valid_dids = [
        "did:plc:z72i7hdynmk6r22z27h6tvur",
        "did:web:blueskyweb.xyz",
        "did:web:example.com%3A3000",
        "did:method:val",
        "did:method:VAL",
        "did:method:val123",
        "did:method:123",
        "did:method:val-two",
        "did:method:val_two",
        "did:method:val.two",
        "did:method:val:two",
        "did:method:val%BB",
        "did:a:b",
        "did:m:" * "a"^2042, # exact 2048 bytes
    ]

    invalid_dids = [
        "",
        "did:",
        "did:plc",
        "did:plc:",
        "did::abc",
        "did:PLC:abc",
        "did:plc1:abc",
        "did:plc-web:abc",
        "did:α:abc",
        "did:plc:α",
        "did:plc:abc:",
        "did:plc:abc%",
        "did:plc:abc?foo=bar",
        "did:plc:abc#frag",
        "did:plc:abc/path",
        "did:plc:abc ",
        "did:plc:abc\n",
        "DID:plc:abc",
        "plc:z72i7hdynmk6r22z27h6tvur",
        "did:m:" * "a"^2043, # 2049 bytes
    ]

    for d in valid_dids
        @test is_valid_did(d)
        @test is_valid_did(SubString(d))
        @test is_valid_did_regex(d)
        @test ensure_valid_did(d) === nothing
        @test ensure_valid_did_regex(d) === nothing
        parsed = tryparse(DID, d)
        @test parsed isa DID
        @test String(parsed) == d
        @test parse(DID, d) == parsed
    end

    for d in invalid_dids
        @test !is_valid_did(d)
        @test !is_valid_did_regex(d)
        @test_throws SyntaxError ensure_valid_did(d)
        @test_throws SyntaxError ensure_valid_did_regex(d)
        @test tryparse(DID, d) === nothing
        @test_throws SyntaxError DID(d)
    end

    d = did"did:plc:z72i7hdynmk6r22z27h6tvur"
    @test did_method(d) == "plc"
    @test did_identifier(d) == "z72i7hdynmk6r22z27h6tvur"
    @test string(d) == "did:plc:z72i7hdynmk6r22z27h6tvur"

    @test valid_did_char('%')
    @test !valid_did_char('#')
    @test !valid_did_char('α')
    @test valid_did_chars("did:plc:abc")
    @test !valid_did_chars("did:plc:abc\n")

    s = "did:plc:z72i7hdynmk6r22z27h6tvur"
    @test (@allocated is_valid_did(s)) == 0
end

@testset "NSIDs" begin
    valid_nsids = [
        "app.bsky.feed.post",
        "com.example.fooBar",
        "com.example.foo2",
        "net.users.bob.ping",
        "a-0.b-1.c",
        "a.b.c",
        "a0.b1.c2",
        "cn.8.lex.stuff",
        "test.12345.record",
        "a.0.c",
        "a.b.c" * "0"^62, # 63-char name
        "App.Bsky.Feed.getAuthorFeed",
    ]

    invalid_nsids = [
        "",
        "com",
        "com.example",
        ".com.example.foo",
        "com.example.foo.",
        "com..example.foo",
        "1com.example.foo",
        "-com.example.foo",
        "com-.example.foo",
        "com.-example.foo",
        "com.example-.foo",
        "com.example.2foo",
        "com.example.foo-bar",
        "com.example.foo_bar",
        "com.example.foo#bar",
        "com.example.fóo",
        "com.example.foo\n",
        "a"^64 * ".b.c",
        "a." * "b"^64 * ".c",
        "a.b." * "c"^64,
        ("a"^63 * ".")^4 * "b.name", # authority > 253 bytes
    ]

    for n in valid_nsids
        @test is_valid_nsid(n)
        @test is_valid_nsid(SubString(n))
        @test is_valid_nsid_regex(n)
        @test ensure_valid_nsid(n) === nothing
        @test ensure_valid_nsid_regex(n) === nothing
        parsed = tryparse(NSID, n)
        @test parsed isa NSID
        @test parse(NSID, n) == parsed
    end

    for n in invalid_nsids
        @test !is_valid_nsid(n)
        @test !is_valid_nsid_regex(n)
        @test_throws SyntaxError ensure_valid_nsid(n)
        @test_throws SyntaxError ensure_valid_nsid_regex(n)
        @test tryparse(NSID, n) === nothing
        @test_throws SyntaxError NSID(n)
    end

    # Round-trip & normalization (authority lowercased, name case-preserved!)
    p = nsid"app.bsky.feed.post"
    @test nsid(p) == "app.bsky.feed.post"
    @test string(p) == "app.bsky.feed.post"
    @test authority(p) == "feed.bsky.app"
    @test name(p) == "post"
    @test NSID("feed.bsky.app", "post") == p
    @test NSID(authority="feed.bsky.app", name="post") == p

    q = NSID("App.Bsky.Feed.getAuthorFeed")
    @test nsid(q) == "app.bsky.feed.getAuthorFeed"
    @test name(q) == "getAuthorFeed"
    @test q == nsid"app.bsky.feed.getAuthorFeed"
    @test q != nsid"app.bsky.feed.getauthorfeed"

    s = "app.bsky.feed.post"
    @test (@allocated is_valid_nsid(s)) == 0
end

@testset "RecordKeys & TIDs" begin
    valid_rkeys = [
        "self",
        "3jui7kd54zh2y",
        "example.com",
        "~1.2-3_",
        "a:b:c",
        "...",
        "a"^512,
    ]
    invalid_rkeys = [
        "",
        ".",
        "..",
        "a/b",
        "a#b",
        "a?b",
        "a b",
        "a@b",
        "α",
        "self\n",
        "a"^513,
    ]

    for r in valid_rkeys
        @test is_valid_record_key(r)
        @test ensure_valid_record_key(r) === nothing
        @test tryparse(RecordKey, r) == RecordKey(r)
    end
    for r in invalid_rkeys
        @test !is_valid_record_key(r)
        @test_throws SyntaxError ensure_valid_record_key(r)
        @test tryparse(RecordKey, r) === nothing
    end
    @test rkey"self" == RecordKey("self")
    @test (@allocated is_valid_record_key("3jui7kd54zh2y")) == 0

    # TIDs
    valid_tids = [
        "3jui7kd54zh2y",
        "2222222222222",
        "jzzzzzzzzzzzz",
    ]
    invalid_tids = [
        "",
        "3jui7kd54zh2",   # too short
        "3jui7kd54zh2yy", # too long
        "k222222222222",  # high bit set (first char > 'j')
        "3JUI7KD54ZH2Y",  # uppercase
        "3jui7kd54zh01",  # 0/1 not in base32-sortable
        "3jui7kd54zh2\n",
    ]
    for t in valid_tids
        @test is_valid_tid(t)
        @test ensure_valid_tid(t) === nothing
        @test tryparse(TID, t) == TID(t)
    end
    for t in invalid_tids
        @test !is_valid_tid(t)
        @test_throws SyntaxError ensure_valid_tid(t)
        @test tryparse(TID, t) === nothing
    end

    t1 = next_tid()
    t2 = next_tid()
    @test t1 < t2
    @test is_valid_tid(String(t1))
    @test 0 <= tid_clockid(t1) <= 1023
    @test tid_timestamp_us(t1) > 1_700_000_000_000_000
    @test convert(RecordKey, t1) == RecordKey(String(t1))
    @test tid"3jui7kd54zh2y" == TID("3jui7kd54zh2y")
    @test (@allocated is_valid_tid("3jui7kd54zh2y")) == 0
end

@testset "ATDateTime" begin
    valid_dts = [
        "1985-04-12T23:20:50.123Z",
        "1985-04-12T23:20:50.123456Z",
        "1985-04-12T23:20:50Z",
        "1985-04-12T23:20:50+00:00",
        "1985-04-12T23:20:50-05:00",
        "2024-02-29T12:00:00Z", # leap year
        "2000-02-29T00:00:00Z", # divisible by 400
    ]
    invalid_dts = [
        "",
        "2023-04-12",
        "2023-04-12 23:20:50Z",       # space instead of T
        "2023-04-12t23:20:50Z",       # lowercase t
        "2023-04-12T23:20:50z",       # lowercase z
        "2023-04-12T23:20:50",        # missing tz
        "2023-04-12T23:20:50-00:00",  # -00:00 disallowed
        "2023-04-12T23:20:50.Z",      # empty fractional part
        "0000-01-01T00:00:00Z",       # year 0000 disallowed
        "2023-02-29T00:00:00Z",       # non-leap year
        "1900-02-29T00:00:00Z",       # century non-leap year
        "2023-13-01T00:00:00Z",       # invalid month
        "2023-04-31T00:00:00Z",       # April has 30 days
        "2023-04-12T24:00:00Z",       # hour 24
        "2023-04-12T23:59:60Z",       # leap second disallowed
        "2023-04-12T23:20:50+24:00",  # invalid tz hour
        "2023-04-12T23:20:50Z\n",
    ]

    for dt in valid_dts
        @test is_valid_datetime(dt)
        @test ensure_valid_datetime(dt) === nothing
        parsed = tryparse(ATDateTime, dt)
        @test parsed isa ATDateTime
        @test String(parsed) == dt
    end
    for dt in invalid_dts
        @test !is_valid_datetime(dt)
        @test_throws SyntaxError ensure_valid_datetime(dt)
        @test tryparse(ATDateTime, dt) === nothing
    end

    # UTC DateTime conversion
    @test Dates.DateTime(ATDateTime("2024-06-01T12:00:00+02:00")) == DateTime(2024, 6, 1, 10, 0, 0)
    @test Dates.DateTime(ATDateTime("2024-06-01T12:00:00.5-05:00")) == DateTime(2024, 6, 1, 17, 0, 0, 500)
    @test ATDateTime(DateTime(2024, 6, 1, 10, 0, 0)) == ATDateTime("2024-06-01T10:00:00.000Z")
    @test (@allocated is_valid_datetime("1985-04-12T23:20:50.123Z")) == 0
end

@testset "AT-URIs" begin
    valid_uris = [
        "at://bsky.app",
        "at://did:plc:z72i7hdynmk6r22z27h6tvur",
        "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post",
        "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y",
        "at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y",
        "at://did:web:example.com/com.example.foo/self",
        "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y#/foo/bar",
        "at://bsky.app#/frag",
    ]

    invalid_uris = [
        "",
        "foo",
        "https://bsky.app",
        "at://",
        "at:///app.bsky.feed.post",
        "at://bsky.app/",
        "at://bsky.app/app.bsky.feed.post/",
        "at://bsky.app/app.bsky.feed.post/self/extra",
        "at://bsky.app/bad_nsid/self",
        "at://did:PLC:abc/app.bsky.feed.post/self",
        "at://bsky.app/app.bsky.feed.post/..",
        "at://bsky.app?query=1",
        "at://bsky.app#",
        "at://bsky.app#no-leading-slash",
        "at://bsky.app#/a#/b",
        "at://bsky.app\n",
        "at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y#/" * "a"^8200, # > 8192 bytes
    ]

    for u in valid_uris
        @test is_valid_aturi(u)
        @test is_valid_aturi(SubString(u))
        @test is_valid_aturi_regex(u)
        @test ensure_valid_aturi(u) === nothing
        parsed = tryparse(AtUri, u)
        @test parsed isa AtUri
        @test parse(AtUri, u) == parsed
        @test parse_aturi(u) == parsed
        @test String(parsed) == u
    end

    for u in invalid_uris
        @test !is_valid_aturi(u)
        @test !is_valid_aturi_regex(u)
        @test_throws SyntaxError ensure_valid_aturi(u)
        @test tryparse(AtUri, u) === nothing
        @test_throws SyntaxError AtUri(u)
    end

    u = at"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"
    @test protocol(u) == "at:"
    @test origin(u) == "at://did:plc:z72i7hdynmk6r22z27h6tvur"
    @test authority(u) == did"did:plc:z72i7hdynmk6r22z27h6tvur"
    @test hostname(u) == "did:plc:z72i7hdynmk6r22z27h6tvur"
    @test collection(u) == nsid"app.bsky.feed.post"
    @test rkey(u) == rkey"3jui7kd54zh2y"
    @test fragment(u) === nothing

    # Authority-only URI accessors don't throw or misreport collection as rkey
    u_auth = at"at://bsky.app"
    @test authority(u_auth) == handle"bsky.app"
    @test collection(u_auth) === nothing
    @test rkey(u_auth) === nothing

    u_col = at"at://bsky.app/app.bsky.feed.post"
    @test collection(u_col) == nsid"app.bsky.feed.post"
    @test rkey(u_col) === nothing

    # Keyword constructor validation
    u_kw = AtUri(handle"bsky.app"; collection="app.bsky.feed.post", rkey="self")
    @test u_kw == at"at://bsky.app/app.bsky.feed.post/self"
    @test_throws SyntaxError AtUri(handle"bsky.app"; rkey="self")
end

@testset "JSON / StructUtils integration" begin
    @test JSON.parse("\"bsky.app\"", Handle) == handle"bsky.app"
    @test JSON.parse("\"did:plc:z72i7hdynmk6r22z27h6tvur\"", DID) == did"did:plc:z72i7hdynmk6r22z27h6tvur"
    @test JSON.parse("\"app.bsky.feed.post\"", NSID) == nsid"app.bsky.feed.post"
    @test JSON.parse("\"3jui7kd54zh2y\"", TID) == tid"3jui7kd54zh2y"
    @test JSON.parse("\"self\"", RecordKey) == rkey"self"
    @test JSON.parse("\"at://bsky.app/app.bsky.feed.post/self\"", AtUri) == at"at://bsky.app/app.bsky.feed.post/self"
    @test JSON.parse("\"2024-06-01T12:00:00Z\"", ATDateTime) == ATDateTime("2024-06-01T12:00:00Z")

    @test JSON.json(handle"Bsky.App") == "\"bsky.app\""
    @test JSON.json(did"did:plc:z72i7hdynmk6r22z27h6tvur") == "\"did:plc:z72i7hdynmk6r22z27h6tvur\""
    @test JSON.json(nsid"app.bsky.feed.post") == "\"app.bsky.feed.post\""
    @test JSON.json(at"at://bsky.app/app.bsky.feed.post/self") == "\"at://bsky.app/app.bsky.feed.post/self\""
end
