using Test
using ATProto
using ATProto.XRPC
using ATProto.DagCbor
using HTTP

# --- canned transport that inspects Authorization headers ------------------------

mutable struct SessionFetch
    responses::Vector{Any}
    calls::Vector{Tuple{String,String,String}}  # (method, url, auth)
end
SessionFetch(pairs) = SessionFetch(Any[p for p in pairs], Tuple{String,String,String}[])

function (f::SessionFetch)(method, url, headers, body; timeout = 30.0)
    auth = ""
    for (k, v) in headers
        lowercase(String(k)) == "authorization" && (auth = String(v))
    end
    push!(f.calls, (String(method), String(url), auth))
    isempty(f.responses) && return HTTP.Response(404, UInt8[])
    resp = popfirst!(f.responses)
    resp isa Exception && throw(resp)
    status, hdrs, b = resp
    return HTTP.Response(status, hdrs, Vector{UInt8}(codeunits(b)))
end

json_response(body; status = 200) = (status, ["Content-Type" => "application/json"], body)
session_body(; did = "did:plc:abc", handle = "alice.example.com",
             access = "access-jwt", refresh = "refresh-jwt") =
    """{"did": "$did", "handle": "$handle", "accessJwt": "$access", "refreshJwt": "$refresh"}"""

@testset "create_session / refresh_session" begin
    fetch = SessionFetch([json_response(session_body())])
    client = XRPCClient(; service = "https://pds.example.com", fetch)
    session = create_session(client, "alice.example.com", "hunter2")

    @test session.did == "did:plc:abc"
    @test session.handle == "alice.example.com"
    @test session.access_jwt == "access-jwt"
    @test session.refresh_jwt == "refresh-jwt"
    method, url, _ = fetch.calls[1]
    @test method == "post"
    @test url == "https://pds.example.com/xrpc/com.atproto.server.createSession"

    # refresh updates tokens in place, using the refresh jwt
    fetch2 = SessionFetch([json_response(session_body(; access = "new-access",
                                                       refresh = "new-refresh"))])
    client2 = XRPCClient(; service = "https://pds.example.com", fetch = fetch2)
    refresh_session!(client2, session)
    @test session.access_jwt == "new-access"
    @test session.refresh_jwt == "new-refresh"
    _, _, auth = fetch2.calls[1]
    @test auth == "Bearer refresh-jwt"

    # invalid createSession responses
    fetch3 = SessionFetch([json_response("{}")])
    client3 = XRPCClient(; service = "https://x", fetch = fetch3)
    @test_throws XRPCError create_session(client3, "a", "b")
end

@testset "SessionClient auto-refresh on 401" begin
    # first call 401s, refresh succeeds, retry succeeds
    fetch = SessionFetch([
        (401, ["Content-Type" => "application/json"],
         """{"error": "AuthenticationRequired", "message": "Expired"}"""),
        json_response(session_body(; access = "fresh-access")),
        json_response("""{"ok": true}"""),
    ])
    base = XRPCClient(; service = "https://pds.example.com", fetch)
    session = AuthSession("did:plc:abc", "alice.example.com", "stale", "refresh")
    sc = SessionClient(base; session)

    res = xrpc_get(sc, "com.example.needsAuth")
    @test res.data["ok"] == true
    @test length(fetch.calls) == 3
    # call 1: stale token; call 2: refresh (refresh token); call 3: fresh token
    @test fetch.calls[1][3] == "Bearer stale"
    @test fetch.calls[2][3] == "Bearer refresh"
    @test fetch.calls[3][3] == "Bearer fresh-access"
    @test session.access_jwt == "fresh-access"

    # 401 twice -> propagates after one retry
    fetch2 = SessionFetch([
        (401, ["Content-Type" => "application/json"], """{"error": "AuthenticationRequired"}"""),
        json_response(session_body(; access = "fresh2")),
        (401, ["Content-Type" => "application/json"], """{"error": "AuthenticationRequired"}"""),
    ])
    session2 = AuthSession("did:plc:abc", "a", "stale", "refresh")
    sc2 = SessionClient(XRPCClient(; service = "https://pds.example.com", fetch = fetch2); session = session2)
    err = try xrpc_get(sc2, "com.example.needsAuth"); nothing catch e; e end
    @test err isa XRPCError
    @test err.status == 401
    @test length(fetch2.calls) == 3

    # non-401 errors pass through without refresh
    fetch3 = SessionFetch([
        (400, ["Content-Type" => "application/json"], """{"error": "InvalidRequest"}"""),
    ])
    session3 = AuthSession("did:plc:abc", "a", "tok", "ref")
    sc3 = SessionClient(XRPCClient(; service = "https://x", fetch = fetch3); session = session3)
    err3 = try xrpc_get(sc3, "x"); nothing catch e; e end
    @test err3 isa XRPCError && err3.status == 400
    @test length(fetch3.calls) == 1
end

@testset "subscribe URL building" begin
    @test subscribe_url("https://bsky.social", "com.atproto.sync.subscribeRepos") ==
          "wss://bsky.social/xrpc/com.atproto.sync.subscribeRepos"
    @test subscribe_url("http://localhost:25841", "com.atproto.sync.subscribeRepos") ==
          "ws://localhost:25841/xrpc/com.atproto.sync.subscribeRepos"
end

@testset "subscribe URL with params" begin
    url = subscribe_url("https://bsky.social", "com.atproto.sync.subscribeRepos";
                        params = Dict("cursor" => 42))
    @test url == "wss://bsky.social/xrpc/com.atproto.sync.subscribeRepos?cursor=42"
    url2 = subscribe_url("https://jetstream.example", "x";
                         params = ["a" => 1, "b" => 2])
    @test url2 == "wss://jetstream.example/xrpc/x?a=1&b=2"
end

@testset "frame splitting" begin
    # a subscription frame: dag-cbor header map + trailing payload bytes
    header = Dict{String,Any}("op" => 1, "t" => "#commit")
    payload = hex2bytes("deadbeef")
    frame = vcat(dag_cbor_encode(header), payload)
    parts = split_frame(frame)
    @test parts.header["op"] == 1
    @test parts.header["t"] == "#commit"
    @test parts.payload == payload

    # nested values and strings in headers
    header2 = Dict{String,Any}("op" => 1, "t" => "#account",
                               "seq" => 12345, "name" => "did:plc:abc")
    frame2 = vcat(dag_cbor_encode(header2), UInt8[])
    parts2 = split_frame(frame2)
    @test parts2.header["seq"] == 12345
    @test parts2.header["name"] == "did:plc:abc"
    @test isempty(parts2.payload)
end
