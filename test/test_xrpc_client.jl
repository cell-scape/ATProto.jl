using Test
using ATProto
using ATProto.XRPC
using ATProto.Crypto
using ATProto.DagCbor
using HTTP
using Dates

# --- canned transport ------------------------------------------------------------

mutable struct Call
    method::String
    url::String
    headers::Vector{Pair{String,String}}
    body
end

mutable struct CannedFetch
    responses::Vector{Any}  # (status, headers, body) or Exception
    calls::Vector{Call}
end
CannedFetch(pairs::Vector{Any}) = CannedFetch(pairs, Call[])

function (f::CannedFetch)(method, url, headers, body; timeout = 30.0)
    push!(f.calls, Call(String(method), String(url),
                        Pair{String,String}[String(k) => String(v) for (k, v) in headers], body))
    isempty(f.responses) && return HTTP.Response(404, UInt8[])
    resp = popfirst!(f.responses)
    resp isa Exception && throw(resp)
    status, hdrs, body = resp
    return HTTP.Response(status, hdrs, Vector{UInt8}(codeunits(body)))
end

json_response(body; status = 200) =
    (status, ["Content-Type" => "application/json"], body)

@testset "query param encoding" begin
    @test encode_query_param("string", "hello world") == "hello world"
    @test encode_query_param("integer", 42) == "42"
    @test encode_query_param("integer", 99.7) == "99"  # truncated like the TS ref
    @test encode_query_param("float", 1.5) == "1.5"
    @test encode_query_param("boolean", true) == "true"
    @test encode_query_param("boolean", false) == "false"
    @test encode_query_param("datetime", DateTime(2023, 6, 1, 12, 0, 0)) == "2023-06-01T12:00:00.000Z"
    @test encode_query_param("datetime", "2023-01-01T00:00:00Z") == "2023-01-01T00:00:00Z"
    @test_throws ArgumentError encode_query_param("weird", "x")
end

@testset "method call URL construction" begin
    @test construct_method_call_url("com.example.foo") == "/xrpc/com.example.foo"
    @test construct_method_call_url("app.bsky.feed.getFeed",
                                    Dict("limit" => 10);
                                    param_types = Dict("limit" => "integer")) ==
          "/xrpc/app.bsky.feed.getFeed?limit=10"
    # Dict params iterate in sorted key order (deterministic)
    @test construct_method_call_url("app.bsky.feed.searchPosts",
                                    Dict("q" => "hello", "limit" => "5")) ==
          "/xrpc/app.bsky.feed.searchPosts?limit=5&q=hello"
    # Vector{Pair} params preserve the given order
    @test construct_method_call_url("app.bsky.feed.searchPosts",
                                    ["q" => "hello", "limit" => 5];
                                    param_types = Dict("q" => "string", "limit" => "integer")) ==
          "/xrpc/app.bsky.feed.searchPosts?q=hello&limit=5"
    # arrays repeat the key
    url = construct_method_call_url("com.example.list",
                                    Dict("ids" => [1, 2, 3]);
                                    param_types = Dict("ids" => ("array", "integer")))
    @test occursin("ids=1&ids=2&ids=3", url)
    # nothing params are skipped
    @test construct_method_call_url("x", Dict("a" => nothing)) == "/xrpc/x"
    # nsid is escaped
    @test construct_method_call_url("com.example.foo/bar") == "/xrpc/com.example.foo%2Fbar"
end

@testset "lex JSON serialization" begin
    cid = cid_for_dagcbor("x")
    value = Dict{String,Any}(
        "text" => "hello",
        "n" => 42,
        "f" => 1.5,
        "flag" => true,
        "nothing" => nothing,  # dropped
        "bytes" => DagBytes(hex2bytes("deadbeef")),
        "link" => cid,
        "list" => Any[1, "two", DagBytes(hex2bytes("00"))],
    )
    json = serialize_lex(value)
    roundtrip = parse_lex(json)
    @test roundtrip["text"] == "hello"
    @test roundtrip["n"] == 42
    @test roundtrip["f"] == 1.5
    @test roundtrip["flag"] === true
    @test !haskey(roundtrip, "nothing")
    @test roundtrip["bytes"] == DagBytes(hex2bytes("deadbeef"))
    @test roundtrip["link"] == cid
    @test roundtrip["list"][3] == DagBytes(hex2bytes("00"))
    @test_throws ArgumentError serialize_lex(Dict(1 => 2))
    @test_throws ArgumentError serialize_lex(:symbol)
end

@testset "XRPC client calls" begin
    # successful JSON query
    fetch = CannedFetch(Any[
        json_response("""{"name": "test", "did": "did:plc:ewvi7nx4oun5hl7s6yqkgcto"}"""),
    ])
    client = XRPCClient(; service = "https://pds.example.com", fetch)
    res = xrpc_get(client, "com.example.getSession")
    @test res.data["name"] == "test"
    call = fetch.calls[1]
    @test call.method == "get"
    @test call.url == "https://pds.example.com/xrpc/com.example.getSession"

    # procedure with JSON body
    fetch2 = CannedFetch(Any[json_response("{}")])
    client2 = XRPCClient(; service = "https://pds.example.com", fetch = fetch2)
    xrpc_proc(client2, "com.example.createThing";
        data = Dict("name" => "thing", "blob" => DagBytes(hex2bytes("cafe"))),
        encoding = "application/json")
    call2 = fetch2.calls[1]
    @test call2.method == "post"
    ct = [v for (k, v) in call2.headers if lowercase(k) == "content-type"]
    @test ct == ["application/json"]
    body = parse_lex(String(call2.body))
    @test body["name"] == "thing"
    @test body["blob"] == DagBytes(hex2bytes("cafe"))

    # raw bytes upload with custom encoding
    fetch3 = CannedFetch(Any[json_response("{}")])
    client3 = XRPCClient(; service = "https://x.example", fetch = fetch3)
    xrpc_proc(client3, "com.atproto.repo.uploadBlob";
        data = hex2bytes("00ff00ff"), encoding = "application/octet-stream")
    @test fetch3.calls[1].body == hex2bytes("00ff00ff")

    # params on the wire
    fetch4 = CannedFetch(Any[json_response("{}")])
    client4 = XRPCClient(; service = "https://x.example", fetch = fetch4)
    xrpc_get(client4, "com.example.search"; params = Dict("q" => "a b", "n" => 3),
             param_types = Dict("q" => "string", "n" => "integer"))
    @test fetch4.calls[1].url == "https://x.example/xrpc/com.example.search?n=3&q=a%20b"

    # error responses
    fetch5 = CannedFetch(Any[(400, ["Content-Type" => "application/json"],
                                """{"error": "InvalidRequest", "message": "bad input"}""")])
    client5 = XRPCClient(; service = "https://x.example", fetch = fetch5)
    err = try xrpc_get(client5, "com.example.f"); nothing catch e; e end
    @test err isa XRPCError
    @test err.status == 400
    @test err.error == "InvalidRequest"
    @test err.message == "bad input"

    # error body without message fields -> generic
    fetch6 = CannedFetch(Any[(500, ["Content-Type" => "text/plain"], "oops")])
    client6 = XRPCClient(; service = "https://x.example", fetch = fetch6)
    err6 = try xrpc_get(client6, "com.example.f"); nothing catch e; e end
    @test err6.status == 500
    @test err6.error === nothing
    @test err6.message == "Internal Server Error"

    # body expected but missing
    client7 = XRPCClient(; service = "https://x.example", fetch = CannedFetch(Any[]))
    @test_throws XRPCError xrpc_call(client7, "x"; method = :post, encoding = "application/json")

    # text response parsing
    fetch8 = CannedFetch(Any[(200, ["Content-Type" => "text/plain"], "plain text")])
    client8 = XRPCClient(; service = "https://x.example", fetch = fetch8)
    @test xrpc_get(client8, "x").data == "plain text"

    # binary response parsing
    fetch9 = CannedFetch(Any[(200, ["Content-Type" => "application/octet-stream"], "\x01\x02")])
    client9 = XRPCClient(; service = "https://x.example", fetch = fetch9)
    @test xrpc_get(client9, "x").data == UInt8[0x01, 0x02]
end
