using Test
using ATProto
using ATProto.Crypto
using ATProto.DagCbor

include(joinpath(@__DIR__, "fixtures", "reference_fixtures.jl"))

# Interpret the typed fixture notation into native Julia values.
function to_value(v)
    t = v.t
    if t === :i
        return v.v
    elseif t === :f
        return Float64(v.v)
    elseif t === :s
        return v.v
    elseif t === :b
        return DagBytes(hex2bytes(v.hex))
    elseif t === :bool
        return v.v
    elseif t === :nul
        return nothing
    elseif t === :cid
        return cid_parse(v.string)
    elseif t === :arr
        return Any[to_value(x) for x in v.v]
    elseif t === :map
        d = Dict{String,Any}()
        for (k, val) in v.v
            d[k] = to_value(val)
        end
        return d
    end
    error("unknown fixture type: $t")
end

@testset "DAG-CBOR reference vectors" begin
    for v in FIXTURES.dagcbor2
        bytes = hex2bytes(v.bytes_hex)
        expected = to_value(v.value)

        # decode matches the expected value
        decoded = dag_cbor_decode(bytes)
        @test decoded == expected

        # encode produces the exact canonical bytes
        @test dag_cbor_encode(expected) == bytes

        # and round-trips
        @test dag_cbor_decode(dag_cbor_encode(expected)) == expected
    end
end

@testset "DAG-CBOR extra encodings" begin
    # full native integer ranges (beyond the JS safe-integer range)
    @test dag_cbor_encode(typemax(Int64)) == vcat(0x1b, hex2bytes("7fffffffffffffff"))
    @test dag_cbor_decode(vcat(0x1b, hex2bytes("7fffffffffffffff"))) == typemax(Int64)
    @test dag_cbor_encode(typemin(Int64)) == vcat(0x3b, hex2bytes("7fffffffffffffff"))
    @test dag_cbor_decode(vcat(0x3b, hex2bytes("7fffffffffffffff"))) == typemin(Int64)
    @test dag_cbor_encode(typemax(UInt64)) == vcat(0x1b, hex2bytes("ffffffffffffffff"))
    @test dag_cbor_decode(vcat(0x1b, hex2bytes("ffffffffffffffff"))) == typemax(UInt64)

    # BigInt within native range encodes; beyond rejects
    @test dag_cbor_encode(BigInt(typemax(Int64))) == dag_cbor_encode(typemax(Int64))
    @test_throws ArgumentError dag_cbor_encode(BigInt(2)^64)
    @test_throws ArgumentError dag_cbor_encode(-(BigInt(2)^64))

    # Float16/Float32 rejected on encode
    @test_throws ArgumentError dag_cbor_encode(Float32(1.0))
    @test_throws ArgumentError dag_cbor_encode(Float16(1.0))

    # NamedTuple encodes as a map
    @test dag_cbor_encode((a = 1, b = "x")) == dag_cbor_encode(Dict("a" => 1, "b" => "x"))

    # unsorted input maps are canonically re-sorted on encode
    unsorted = Dict("b" => 4, "ab" => 3, "aa" => 2, "a" => 1)
    sorted = Dict("a" => 1, "b" => 4, "aa" => 2, "ab" => 3)
    @test dag_cbor_encode(unsorted) == dag_cbor_encode(sorted)

    # unencodable types
    @test_throws ArgumentError dag_cbor_encode(:symbol)
    @test_throws ArgumentError dag_cbor_encode(Dict(1 => 2))
end

@testset "DAG-CBOR malformed input" begin
    bad = [
        ("empty input", UInt8[]),
        ("trailing bytes", [0x01, 0x02]),
        ("truncated argument", [0x18]),
        ("truncated uint16 arg", [0x19, 0x01]),
        ("truncated bytes", [0x43, 0x01, 0x02]),              # 3-byte string, 2 given
        ("truncated text", [0x62, 0x61]),                     # 2-char text, 1 given
        ("invalid UTF-8", [0x62, 0xff, 0xfe]),
        ("indefinite array", [0x9f, 0xff]),
        ("indefinite text", [0x7f, 0x61, 0x61, 0xff]),
        ("indefinite map", [0xbf, 0xff]),
        ("float16", [0xf9, 0x3c, 0x00]),                      # 1.0h
        ("float32", [0xfa, 0x3f, 0x80, 0x00, 0x00]),          # 1.0f
        ("unknown tag", [0xc0, 0x01]),                        # tag 0
        ("bignum tag 2", [0xc2, 0x41, 0x01]),                 # forbidden by spec
        ("bignum tag 3", [0xc3, 0x41, 0x01]),
        ("tag 42 non-bytes", [0xd8, 0x2a, 0x01]),             # tag(42, int)
        ("tag 42 bad prefix", [0xd8, 0x2a, 0x42, 0x01, 0x02]), # no 0x00 prefix
        ("tag 42 invalid cid", [0xd8, 0x2a, 0x45, 0x00, 0x02, 0x01, 0x02, 0x03]),  # bad CID body
        ("undefined", [0xf7]),
        ("non-string map key", [0xa1, 0x01, 0x02]),           # key is int 1
        ("unsorted map keys", [0xa2, 0x61, 0x62, 0x01, 0x61, 0x61, 0x02]),   # {"b":1,"a":2}
        ("duplicate map keys", [0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02]),   # {"a":1,"a":2}
    ]
    for (name, bytes) in bad
        @test_throws Exception dag_cbor_decode(bytes)
    end

    # unsorted keys ordering edge: length-first, so {"aa" then "b"} is invalid
    @test_throws Exception dag_cbor_decode([0xa2, 0x62, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02])
    # ...while {"b" then "aa"} (sorted) is fine
    @test dag_cbor_decode([0xa2, 0x61, 0x62, 0x02, 0x62, 0x61, 0x61, 0x01]) ==
          Dict("b" => 2, "aa" => 1)
end

@testset "DAG-CBOR CIDs" begin
    cid = cid_for_dagcbor("block bytes")
    encoded = dag_cbor_encode(Dict("link" => cid))
    decoded = dag_cbor_decode(encoded)
    @test decoded["link"] == cid
    @test decoded["link"] isa CID
    # nested CIDs
    doc = Dict("list" => Any[cid, Dict("inner" => cid)])
    @test dag_cbor_decode(dag_cbor_encode(doc)) == doc
end
