using Test
using ATProto
using ATProto.API
using ATProto.Lexicon
using HTTP
using JSON

# --- canned transport -----------------------------------------------------------

mutable struct ApiFetch
    responses::Vector{Any}  # (status, ctype, body) or regex-matched dispatch
    routes::Vector{Pair{Regex,Any}}
    calls::Vector{Tuple{String,String,String}}
end
ApiFetch() = ApiFetch(Any[], Pair{Regex,Any}[], Tuple{String,String,String}[])

function (f::ApiFetch)(method, url, headers, body; timeout = 30.0)
    auth = ""
    for (k, v) in headers
        lowercase(String(k)) == "authorization" && (auth = String(v))
    end
    push!(f.calls, (String(method), String(url), auth))
    for (pattern, resp) in f.routes
        occursin(pattern, url) && return _mk(resp)
    end
    isempty(f.responses) || return _mk(popfirst!(f.responses))
    return HTTP.Response(404, UInt8[])
end

function _mk(resp)
    resp isa Exception && throw(resp)
    status, ctype, body = resp
    return HTTP.Response(status, ["Content-Type" => ctype], Vector{UInt8}(codeunits(body)))
end

json(body; status = 200) = (status, "application/json", body)

@testset "generated namespaces" begin
    # every official XRPC method has a Julian snake_case form
    queries = sum(1 for (nsid, doc) in OFFICIAL_LEXICONS.docs
                  if get(get(doc["defs"], "main", Dict()), "type", "") == "query")
    procedures = sum(1 for (nsid, doc) in OFFICIAL_LEXICONS.docs
                     if get(get(doc["defs"], "main", Dict()), "type", "") == "procedure")
    @test queries + procedures == 322

    @test isdefined(API.com.atproto.server, :create_session)
    @test isdefined(API.com.atproto.server, :refresh_session)
    @test isdefined(API.com.atproto.repo, :create_record)
    @test isdefined(API.com.atproto.repo, :apply_writes)
    @test isdefined(API.com.atproto.sync, :subscribe_repos)
    @test isdefined(API.app.bsky.feed, :get_timeline)
    @test isdefined(API.app.bsky.feed, :search_posts)
    @test isdefined(API.app.bsky.actor, :get_profile)
    @test isdefined(API.tools.ozone.moderation, :emit_event)
end

@testset "generated query call" begin
    f = ApiFetch()
    push!(f.routes,
        r"com\.atproto\.identity\.resolveHandle" =>
        json("""{"did": "did:plc:ewvi7nx4oun5hl7s6yqkgcto"}"""))
    agent = Agent(; service = "https://pds.example.com", fetch = f)

    res = API.com.atproto.identity.resolve_handle(agent; handle = "alice.example.com")
    did = res["did"]
    @test did == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
    method, url, _ = f.calls[1]
    @test method == "get"
    @test occursin("handle=alice.example.com", url)

    # param validation fires from the lexicon (handle is required)
    @test_throws LexiconValidationError API.com.atproto.identity.resolve_handle(agent)
end

@testset "generated procedure call with input validation" begin
    f = ApiFetch()
    push!(f.routes,
        r"com\.atproto\.repo\.createRecord" =>
        json("""{"uri": "at://did:plc:abc/com.example.post/3jzfcijpj2z2a",
                  "cid": "bafyreigebku4q3pal7hveauaiwi4ty5swf7yif2kkt5vdyixgyxdnsdly3m",
                  "commit": {"cid": "bafyreigebku4q3pal7hveauaiwi4ty5swf7yif2kkt5vdyixgyxdnsdly3m",
                             "rev": "3jzfcijpj2z2a"}}"""))
    agent = Agent(; service = "https://pds.example.com", fetch = f)

    record = Dict{String,Any}("\$type" => "app.bsky.feed.post",
                              "text" => "hello",
                              "createdAt" => "2023-06-01T12:00:00.000Z")
    res = API.com.atproto.repo.create_record(agent;
        data = Dict{String,Any}("repo" => "did:plc:abc",
                                "collection" => "app.bsky.feed.post",
                                "rkey" => "3jzfcijpj2z2a",
                                "record" => record))
    @test startswith(res["uri"], "at://did:plc:abc/")
    method, url, auth = f.calls[1]
    @test method == "post"
    @test url == "https://pds.example.com/xrpc/com.atproto.repo.createRecord"

    # input validated against the lexicon: missing required fields
    @test_throws LexiconValidationError API.com.atproto.repo.create_record(agent;
        data = Dict{String,Any}("repo" => "did:plc:abc"))
end

@testset "login and session flows" begin
    f = ApiFetch()
    push!(f.routes,
        r"createSession" =>
        json("""{"did": "did:plc:abc", "handle": "alice.example.com",
                  "accessJwt": "access-1", "refreshJwt": "refresh-1"}"""))
    push!(f.routes,
        r"app\.bsky\.feed\.getTimeline" =>
        json("""{"feed": []}"""))
    agent = Agent(; service = "https://pds.example.com", fetch = f)

    sa = login(agent, "alice.example.com", "hunter2")
    @test sa isa SessionAgent
    @test did_of(sa) == "did:plc:abc"
    @test handle_of(sa) == "alice.example.com"
    @test session_of(sa).access_jwt == "access-1"

    # authenticated generated call carries the bearer token
    timeline = API.app.bsky.feed.get_timeline(sa)
    @test timeline["feed"] == []
    _, _, auth = f.calls[end]
    @test auth == "Bearer access-1"
end

@testset "record conveniences" begin
    f = ApiFetch()
    push!(f.routes,
        r"com\.atproto\.repo\.createRecord" =>
        json("""{"uri": "at://did:plc:abc/app.bsky.feed.post/3jzfcijpj2z2a",
                  "cid": "bafyreigebku4q3pal7hveauaiwi4ty5swf7yif2kkt5vdyixgyxdnsdly3m",
                  "commit": {"cid": "bafyreigebku4q3pal7hveauaiwi4ty5swf7yif2kkt5vdyixgyxdnsdly3m",
                             "rev": "3jzfcijpj2z2a"}}"""))
    push!(f.routes,
        r"com\.atproto\.repo\.deleteRecord" => json("""{}"""))
    push!(f.routes,
        r"createSession" =>
        json("""{"did": "did:plc:abc", "handle": "alice.example.com",
                  "accessJwt": "a", "refreshJwt": "r"}"""))
    push!(f.routes,
        r"com\.atproto\.repo\.uploadBlob" =>
        json("""{"blob": {"\$type": "blob",
                          "ref": {"\$link": "bafyreigebku4q3pal7hveauaiwi4ty5swf7yif2kkt5vdyixgyxdnsdly3m"},
                          "mimeType": "image/png", "size": 4}}"""))
    agent = Agent(; service = "https://pds.example.com", fetch = f)
    sa = login(agent, "alice.example.com", "pw")

    # create_post: builds the app.bsky.feed.post record
    res = create_post(sa, "hello world")
    @test startswith(res["uri"], "at://did:plc:abc/app.bsky.feed.post/")
    # delete_post
    del = delete_post(sa, "3jzfcijpj2z2a")
    @test del == Dict{String,Any}()

    # upload_blob returns a BlobRef
    br = upload_blob(sa, UInt8[0x01, 0x02, 0x03, 0x04], "image/png")
    @test br isa ATProto.Lexicon.BlobRef
    @test br.mime_type == "image/png"
    @test br.size == 4
end

@testset "subscribe URL building" begin
    # no live socket: verify the param types the generated method would use
    ptypes = API.param_types_for("com.atproto.sync.subscribeRepos")
    @test haskey(ptypes, "cursor")
    @test ptypes["cursor"]["type"] == "integer"
    @test subscribe_url("https://bsky.social", "com.atproto.sync.subscribeRepos";
                        params = Dict("cursor" => 1)) ==
          "wss://bsky.social/xrpc/com.atproto.sync.subscribeRepos?cursor=1"
end
