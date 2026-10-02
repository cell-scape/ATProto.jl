using Test
using ATProto
using ATProto.Crypto

include(joinpath(@__DIR__, "fixtures", "reference_fixtures.jl"))

@testset "CID" begin
    @testset "reference vectors" begin
        for v in FIXTURES.cids
            input = isempty(v.input_hex) ? UInt8[] : hex2bytes(v.input_hex)
            mh = hex2bytes(v.multihash_hex)

            # multihash derivation
            @test sha256_multihash(input) == mh

            # v1 construction and all serializations
            cid1 = CID(1, DAG_CBOR_CODEC, mh)
            @test string(cid1) == v.v1_string
            @test cid_bytes(cid1) == hex2bytes(v.v1_bytes)
            @test cid_parse(v.v1_string) == cid1
            @test cid_parse("z" * base58btc_encode(cid_bytes(cid1))) == cid1
            @test "z" * base58btc_encode(cid_bytes(cid1)) == v.v1_base58

            # v0 construction
            cid0 = CID(0, DAG_PB_CODEC, mh)
            @test string(cid0) == v.v0_string
            @test cid_bytes(cid0) == mh
            @test cid_parse(v.v0_string) == cid0

            # v0 dag-pb is equivalent to v1 dag-pb with same digest
            @test CID(0, DAG_PB_CODEC, mh) == CID(1, DAG_PB_CODEC, mh)
            @test cid0 != cid1  # different codecs

            # convenience constructor
            @test cid_for_dagcbor(input) == cid1
        end
    end

    @testset "parses" begin
        for v in FIXTURES.cid_parses
            cid = cid_parse(v.string)
            @test cid.version == v.version
            @test cid.codec == v.codec
            @test cid_bytes(cid) == hex2bytes(v.bytes)
        end
    end

    @testset "errors" begin
        @test_throws InvalidCidError cid_parse("")
        @test_throws InvalidCidError cid_parse("bnothex!")
        @test_throws InvalidCidError cid_parse("Qmshort")          # bad v0 length
        @test_throws InvalidCidError CID(2, 0x71, sha256_multihash(""))
        @test_throws InvalidCidError CID(0, DAG_CBOR_CODEC, sha256_multihash(""))
        @test_throws InvalidCidError cid_from_bytes(UInt8[0x02, 0x71])
        @test_throws InvalidCidError CID(1, DAG_CBOR_CODEC, UInt8[0x13, 0x20])  # unsupported mh
    end

    @testset "codec names" begin
        @test cid_codec_name(DAG_CBOR_CODEC) == "dag-cbor"
        @test cid_codec_name(RAW_CODEC) == "raw"
        @test cid_codec_name(DAG_PB_CODEC) == "dag-pb"
        @test cid_codec_name(UInt64(0x9999)) == "codec-0x9999"
    end

    @testset "ordering/hashing" begin
        a = cid_for_dagcbor("a")
        b = cid_for_dagcbor("b")
        @test a == cid_for_dagcbor("a")
        @test a != b
        @test hash(a) == hash(cid_for_dagcbor("a"))
        @test string(a) == string(cid_for_dagcbor("a"))
        @test startswith(string(a), "b")  # base32 multibase prefix
    end
end
