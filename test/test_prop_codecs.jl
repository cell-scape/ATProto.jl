# Property-based tests for the codec layers, using Supposition.jl
# (the Julia Hypothesis port). Shrunk counterexamples from these would have
# caught the MST prefix off-by-one and encoding edge cases immediately.
using Test
using Supposition
using ATProto
using ATProto.Crypto
using ATProto.DagCbor

using Supposition: Data

const ByteVectors = Data.Vectors(Data.Integers(0x00, 0xff);
                                 min_size = 0, max_size = 256)

@testset "property: base codecs" begin
    @check function base58_roundtrip(bytes = ByteVectors)
        base58btc_decode(base58btc_encode(bytes)) == bytes
    end

    @check function base32_roundtrip(bytes = ByteVectors)
        base32_decode(base32_encode(bytes)) == bytes
    end

    @check function base16_roundtrip(bytes = ByteVectors)
        base16_decode(base16_encode(bytes)) == bytes
    end

    @check function base64_roundtrip(bytes = ByteVectors)
        base64_decode(base64_encode(bytes)) == bytes &&
        base64url_decode(base64url_encode(bytes)) == bytes
    end
end

@testset "property: multibase" begin
    encodings = Data.SampledFrom([:base16, :base32, :base58btc, :base64, :base64url])
    @check function multibase_roundtrip(bytes = ByteVectors, enc = encodings)
        multibase_to_bytes(bytes_to_multibase(bytes; encoding = enc)) == bytes
    end
end

@testset "property: varint" begin
    @check function varint_roundtrip(u = Data.Integers(UInt64(0), typemax(UInt64)))
        varint_decode(varint_encode(u)) == u
    end
    @check function varint_prefix_roundtrip(u = Data.Integers(UInt64(0), typemax(UInt64)),
                                            pad = Data.Integers(0, 4))
        # decoding at a position skips exactly the encoded bytes
        bytes = vcat(varint_encode(u), UInt8(0xff), UInt8(0xff))
        (value, next) = read_varint(bytes; pos = 1)
        value == u && next == length(varint_encode(u)) + 1
    end
end

@testset "property: CID" begin
    @check function cid_string_roundtrip(data = ByteVectors)
        cid = cid_for_dagcbor(data)
        cid_parse(string(cid)) == cid
    end
    @check function cid_bytes_roundtrip(data = ByteVectors)
        cid = cid_for_dagcbor(data)
        cid_from_bytes(cid_bytes(cid)) == cid
    end
    @check function cid_base58_form(data = ByteVectors)
        cid = cid_for_dagcbor(data)
        cid_parse("z" * base58btc_encode(cid_bytes(cid))) == cid
    end
end

@testset "property: digests" begin
    @check function sha256_len(data = ByteVectors)
        length(sha256(data)) == 32
    end
    @check function ripemd160_len(data = ByteVectors)
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

    @check function dagcbor_roundtrip(v = dag_values)
        dag_cbor_decode(dag_cbor_encode(v)) == v
    end
end
