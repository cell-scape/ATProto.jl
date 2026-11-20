# Property-based tests for the codec layers, using Supposition.jl
# (the Julia Hypothesis port). Shrunk counterexamples from these would have
# caught the MST prefix off-by-one and encoding edge cases immediately.
using Test
using Supposition
using ATProto
using ATProto.Crypto
using ATProto.DagCbor

using Supposition: Data

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

macro _pcheck(args...)
    chk = Expr(:macrocall, GlobalRef(Supposition, Symbol("@check")), __source__, :(db = false), args...)
    return quote
        let _ts = _with_isolated_testset(() -> $(esc(chk)))
            _ok = !Test.anynonpass(_ts)
            _ok || @error sprint(Test.print_test_results, _ts)
            @test _ok
        end
    end
end

const ByteVectors = Data.Vectors(Data.Integers(0x00, 0xff);
                                 min_size = 0, max_size = 256)

@testset "property: base codecs" begin
    @_pcheck function base58_roundtrip(bytes = ByteVectors)
        base58btc_decode(base58btc_encode(bytes)) == bytes
    end

    @_pcheck function base32_roundtrip(bytes = ByteVectors)
        base32_decode(base32_encode(bytes)) == bytes
    end

    @_pcheck function base16_roundtrip(bytes = ByteVectors)
        base16_decode(base16_encode(bytes)) == bytes
    end

    @_pcheck function base64_roundtrip(bytes = ByteVectors)
        base64_decode(base64_encode(bytes)) == bytes &&
        base64url_decode(base64url_encode(bytes)) == bytes
    end
end

@testset "property: multibase" begin
    encodings = Data.SampledFrom([:base16, :base32, :base58btc, :base64, :base64url])
    @_pcheck function multibase_roundtrip(bytes = ByteVectors, enc = encodings)
        multibase_to_bytes(bytes_to_multibase(bytes; encoding = enc)) == bytes
    end
end

@testset "property: varint" begin
    @_pcheck function varint_roundtrip(u = Data.Integers(UInt64(0), typemax(UInt64)))
        varint_decode(varint_encode(u)) == u
    end
    @_pcheck function varint_prefix_roundtrip(u = Data.Integers(UInt64(0), typemax(UInt64)),
                                            pad = Data.Integers(0, 4))
        # decoding at a position skips exactly the encoded bytes
        bytes = vcat(varint_encode(u), UInt8(0xff), UInt8(0xff))
        (value, next) = read_varint(bytes; pos = 1)
        value == u && next == length(varint_encode(u)) + 1
    end
end

@testset "property: CID" begin
    @_pcheck function cid_string_roundtrip(data = ByteVectors)
        cid = cid_for_dagcbor(data)
        cid_parse(string(cid)) == cid
    end
    @_pcheck function cid_bytes_roundtrip(data = ByteVectors)
        cid = cid_for_dagcbor(data)
        cid_from_bytes(cid_bytes(cid)) == cid
    end
    @_pcheck function cid_base58_form(data = ByteVectors)
        cid = cid_for_dagcbor(data)
        cid_parse("z" * base58btc_encode(cid_bytes(cid))) == cid
    end
end

@testset "property: digests" begin
    @_pcheck function sha256_len(data = ByteVectors)
        length(sha256(data)) == 32
    end
    @_pcheck function ripemd160_len(data = ByteVectors)
        length(ripemd160(data)) == 20
    end
end

@testset "property: DAG-CBOR round trip" begin
    # structured value trees over the lexicon-compatible subset
    ints = Data.Integers(-(2^53), 2^53)
    strings = Data.Text(Data.AsciiCharacters(); min_len = 0, max_len = 64)
    bools = Data.Booleans()

    leaf_values = ints | strings | bools | Data.Just(nothing)

    extend(inner) = begin
        vecs = Data.Vectors(inner; min_size = 0, max_size = 4)
        maps = Data.map(pairs -> Dict{String,Any}(string(i) => v for (i, v) in enumerate(pairs)),
                        Data.Vectors(inner; min_size = 0, max_size = 4))
        leaf_values | vecs | maps
    end
    dag_values = Data.recursive(extend, leaf_values; max_layers = 3)

    @_pcheck function dagcbor_roundtrip(v = dag_values)
        dag_cbor_decode(dag_cbor_encode(v)) == v
    end
end
