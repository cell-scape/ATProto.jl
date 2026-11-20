using ATProto
using ATProto.Syntax
using ATProto.Jetstream
using Dates
using JSON
using Supposition
using Supposition.Data
using Test

const _ASCII_LOWER = Data.SampledFrom(collect('a':'z'))
const _ASCII_ALPHA = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z')))
const _ASCII_ALNUM = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9')))
const _LABEL_MID_CHAR = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9'), ['-']))
const _DID_ID_CHAR = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9'), ['.', '_', ':', '%', '-']))
const _DID_END_CHAR = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9'), ['.', '_', '-']))
const _RKEY_CHAR = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9'), ['.', '_', '~', ':', '-']))
const _FUZZ_ASCII = Data.SampledFrom(vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9'), ['.', '-', '_', ':', '%', '/', '#', '?', ' ', '\n', '~', '@']))

const _ARB_UNICODE = Data.Text(Data.Characters(); max_len = 80)
const _ARB_SYNTAXISH = Data.Text(_FUZZ_ASCII; max_len = 80)
const _ARB_STRING = Data.OneOf(_ARB_UNICODE, _ARB_SYNTAXISH)

const _VALID_LABEL = @composed function _gen_label(
    first_c = _ASCII_ALNUM,
    mid = Data.Text(_LABEL_MID_CHAR; max_len = 12),
    last_c = _ASCII_ALNUM,
    single = Data.Booleans(),
)
    single && return string(first_c)
    return string(first_c, mid, last_c)
end

const _VALID_TLD = @composed function _gen_tld(
    first_c = _ASCII_ALPHA,
    mid = Data.Text(_LABEL_MID_CHAR; max_len = 10),
    last_c = _ASCII_ALNUM,
    single = Data.Booleans(),
)
    single && return string(first_c)
    return string(first_c, mid, last_c)
end

const _VALID_HANDLE_STR = @composed function _gen_handle(
    labels = Data.Vectors(_VALID_LABEL; min_size = 1, max_size = 4),
    tld = _VALID_TLD,
)
    return join(vcat(labels, [tld]), '.')
end

const _VALID_DID_STR = @composed function _gen_did(
    method = Data.Text(_ASCII_LOWER; min_len = 1, max_len = 8),
    mid = Data.Text(_DID_ID_CHAR; max_len = 24),
    last_c = _DID_END_CHAR,
)
    return string("did:", method, ":", mid, last_c)
end

const _VALID_NSID_STR = @composed function _gen_nsid(
    first_seg = _VALID_TLD,
    mid_segs = Data.Vectors(_VALID_LABEL; min_size = 1, max_size = 3),
    name_first = _ASCII_ALPHA,
    name_rest = Data.Text(_ASCII_ALNUM; max_len = 12),
)
    return join(vcat([first_seg], mid_segs, [string(name_first, name_rest)]), '.')
end

const _VALID_RKEY_STR = @composed function _gen_rkey(
    s = Data.Text(_RKEY_CHAR; min_len = 1, max_len = 32),
)
    (s == "." || s == "..") && return "self"
    return s
end

const _VALID_TID_U64 = Data.Integers(UInt64(0), (UInt64(1) << 63) - UInt64(1))

const _VALID_UTC_DT = @composed function _gen_dt(
    y = Data.Integers(1970, 2100),
    m = Data.Integers(1, 12),
    d = Data.Integers(1, 28),
    H = Data.Integers(0, 23),
    M = Data.Integers(0, 59),
    S = Data.Integers(0, 59),
    ms = Data.Integers(0, 999),
)
    return DateTime(y, m, d, H, M, S, ms)
end

const _VALID_ATURI_STR = @composed function _gen_aturi(
    use_did = Data.Booleans(),
    did = _VALID_DID_STR,
    handle = _VALID_HANDLE_STR,
    has_col = Data.Booleans(),
    col = _VALID_NSID_STR,
    has_rk = Data.Booleans(),
    rk = _VALID_RKEY_STR,
    has_frag = Data.Booleans(),
    frag_body = Data.Text(_ASCII_ALNUM; min_len = 1, max_len = 10),
)
    auth = use_did ? did : handle
    base = if has_col
        has_rk ? string("at://", auth, "/", col, "/", rk) : string("at://", auth, "/", col)
    else
        string("at://", auth)
    end
    return has_frag ? string(base, "#/", frag_body) : base
end

# Run Supposition.@check inside an isolated DefaultTestSet so worker-local closures inside
# SuppositionReport don't cross ParallelTestRunner's Malt serialization boundary.
function _with_isolated_testset(f::Function)
    ts = Test.DefaultTestSet("supposition")
    @static if isdefined(Test, :CURRENT_TESTSET)
        Base.ScopedValues.@with Test.CURRENT_TESTSET => ts begin
            f()
        end
    else
        Test.push_testset(ts)
        try
            f()
        finally
            Test.pop_testset()
        end
    end
    return ts
end

macro _pcheck(expr)
    chk = Expr(:macrocall, GlobalRef(Supposition, Symbol("@check")), __source__, :(db = false), expr)
    return quote
        let _ts = _with_isolated_testset(() -> $(esc(chk)))
            _ok = !Test.anynonpass(_ts)
            _ok || @error sprint(Test.print_test_results, _ts)
            @test _ok
        end
    end
end

@testset "Property-based tests (Supposition.jl)" begin
    @testset "Fuzzing: validators never crash & match regex implementations" begin
        @_pcheck function fuzz_handle(s = _ARB_STRING)
            v1 = is_valid_handle(s)
            v2 = is_valid_handle_regex(s)
            return v1 == v2 && (v1 ? !isnothing(tryparse(Handle, s)) : isnothing(tryparse(Handle, s)))
        end

        @_pcheck function fuzz_did(s = _ARB_STRING)
            v1 = is_valid_did(s)
            v2 = is_valid_did_regex(s)
            return v1 == v2 && (v1 ? !isnothing(tryparse(DID, s)) : isnothing(tryparse(DID, s)))
        end

        @_pcheck function fuzz_nsid(s = _ARB_STRING)
            v1 = is_valid_nsid(s)
            v2 = is_valid_nsid_regex(s)
            return v1 == v2 && (v1 ? !isnothing(tryparse(NSID, s)) : isnothing(tryparse(NSID, s)))
        end

        @_pcheck function fuzz_rkey_tid_dt(s = _ARB_STRING)
            rk_ok = is_valid_record_key(s)
            tid_ok = is_valid_tid(s)
            dt_ok = is_valid_datetime(s)
            return (rk_ok == !isnothing(tryparse(RecordKey, s))) &&
                   (tid_ok == !isnothing(tryparse(TID, s))) &&
                   (dt_ok == !isnothing(tryparse(ATDateTime, s))) &&
                   (!tid_ok || rk_ok) # every valid TID is also a valid RecordKey
        end

        @_pcheck function fuzz_aturi(s = _ARB_STRING)
            v1 = is_valid_aturi(s)
            v2 = is_valid_aturi_regex(s)
            return v1 == v2 && (v1 ? !isnothing(tryparse(AtUri, s)) : isnothing(tryparse(AtUri, s)))
        end

        @_pcheck function fuzz_richtext(s = _ARB_STRING)
            rt = ATProto.RichText.richtext(s)
            segs = ATProto.RichText.segments(rt)
            n = ncodeunits(rt.text)
            prev_end = 0
            for f in rt.facets
                (0 <= f.index.byteStart < f.index.byteEnd <= n) || return false
                f.index.byteStart >= prev_end || return false
                prev_end = f.index.byteEnd
            end
            return join(seg.text for seg in segs) == rt.text
        end
    end

    @testset "Structured round-trip & algebraic invariants" begin
        @_pcheck function handle_roundtrip(s = _VALID_HANDLE_STR)
            h = Handle(s)
            return is_valid_handle(s) &&
                   is_valid_handle_regex(s) &&
                   Handle(uppercase(s)) == h &&
                   Handle(lowercase(s)) == h &&
                   parse(Handle, String(h)) == h
        end

        @_pcheck function did_roundtrip(s = _VALID_DID_STR)
            d = DID(s)
            return is_valid_did(s) &&
                   is_valid_did_regex(s) &&
                   string("did:", did_method(d), ":", did_identifier(d)) == String(d) &&
                   parse(DID, String(d)) == d
        end

        @_pcheck function nsid_roundtrip(s = _VALID_NSID_STR)
            n = NSID(s)
            return is_valid_nsid(s) &&
                   is_valid_nsid_regex(s) &&
                   NSID(authority(n), name(n)) == n &&
                   parse(NSID, nsid(n)) == n
        end

        @_pcheck function tid_order_and_bijection(a = _VALID_TID_U64, b = _VALID_TID_U64)
            ta = TID(Syntax._tid_encode_u64(a))
            tb = TID(Syntax._tid_encode_u64(b))
            return Syntax._tid_decode_u64(String(ta)) == a &&
                   tid_timestamp_us(ta) == Int64(a >> 10) &&
                   tid_clockid(ta) == Int(a & UInt64(0x3ff)) &&
                   ((a < b) == (ta < tb))
        end

        @_pcheck function datetime_roundtrip(dt = _VALID_UTC_DT)
            adt = ATDateTime(dt)
            return is_valid_datetime(String(adt)) && Dates.DateTime(adt) == dt
        end

        @_pcheck function aturi_roundtrip(s = _VALID_ATURI_STR)
            u = AtUri(s)
            u2 = AtUri(authority(u); collection = collection(u), rkey = rkey(u), fragment = fragment(u))
            return is_valid_aturi(s) &&
                   is_valid_aturi_regex(s) &&
                   u == u2 &&
                   parse(AtUri, String(u)) == u
        end

        @_pcheck function jetstream_commit_roundtrip(
            did = _VALID_DID_STR,
            rk = _VALID_RKEY_STR,
            time_us = Data.Integers(Int64(1), Int64(2_000_000_000_000_000)),
            text = Data.Text(_ASCII_ALNUM; max_len = 40),
        )
            frame = JSON.json(Dict(
                "did" => did,
                "time_us" => time_us,
                "kind" => "commit",
                "commit" => Dict(
                    "rev" => "3jui7kd54zh2y",
                    "operation" => "create",
                    "collection" => "app.bsky.feed.post",
                    "rkey" => rk,
                    "cid" => "bafyreitest",
                    "record" => Dict(
                        "\$type" => "app.bsky.feed.post",
                        "text" => text,
                        "createdAt" => "2026-11-19T22:00:00Z",
                    ),
                ),
            ))
            ev = parse_jetstream_event(frame)
            return ev isa JetstreamCommitEvent &&
                   ev.did == DID(did) &&
                   ev.time_us == time_us &&
                   ev.operation === :create &&
                   ev.record isa ATProto.API.AppBskyFeedPost &&
                   ev.record.text == text &&
                   aturi(ev) == AtUri(DID(did); collection = nsid"app.bsky.feed.post", rkey = RecordKey(rk))
        end
    end
end
