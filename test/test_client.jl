using ATProto
using ATProto.API
using ATProto.Client
using ATProto.Syntax
using HTTP
using JSON
using Test

const Sockets = HTTP.Sockets

function _hdr(headers, name::AbstractString)
    lname = lowercase(name)
    for (k, v) in headers
        lowercase(k) == lname && return v
    end
    return nothing
end

function _json_resp(status::Int, obj; headers = Pair{String, String}[])
    hdrs = Pair{String, String}["Content-Type" => "application/json", headers...]
    return HTTP.Response(status, hdrs; body = JSON.json(obj))
end

@testset "XRPC Client & AtpAgent" begin
    @testset "Query parameter encoding" begin
        params = API.App.Bsky.Actor.GetProfiles.Params(
            actors = ["bsky.app", "did:plc:z72i7hdynmk6r22z27h6tvur"],
        )
        qs = Client._encode_query_params(params)
        @test qs == "actors=bsky.app&actors=did%3Aplc%3Az72i7hdynmk6r22z27h6tvur"

        feed_params = API.App.Bsky.Feed.GetAuthorFeed.Params(
            actor = "bsky.app",
            limit = 25,
            includePins = true,
            cursor = nothing,
        )
        qs2 = Client._encode_query_params(feed_params)
        @test occursin("actor=bsky.app", qs2)
        @test occursin("limit=25", qs2)
        @test occursin("includePins=true", qs2)
        @test !occursin("cursor=", qs2)
    end

    @testset "Unified xrpc dispatch & error parsing" begin
        seen = Any[]
        transport = function (method, url, headers, body; timeout)
            push!(seen, (method = method, url = url, headers = headers, body = body))
            if occursin("app.bsky.actor.getProfile", url)
                return _json_resp(
                    200,
                    Dict("did" => "did:plc:z72i7hdynmk6r22z27h6tvur", "handle" => "bsky.app", "displayName" => "Bluesky");
                    headers = [
                        "RateLimit-Limit" => "3000",
                        "RateLimit-Remaining" => "2999",
                        "RateLimit-Reset" => "1700000000",
                        "RateLimit-Policy" => "3000;w=300",
                    ],
                )
            elseif occursin("app.bsky.feed.getPostThread", url)
                return _json_resp(400, Dict("error" => "NotFound", "message" => "Post not found"))
            end
            return HTTP.Response(404, body = "not found")
        end

        agent = AtpAgent(PUBLIC_APPVIEW; transport)
        @test !is_authenticated(agent)
        @test service_url(agent) == PUBLIC_APPVIEW
        @test rate_limit(agent) === nothing

        # Dispatch via String, NSID, QueryEndpoint, and namespace Module (including Handle/DID auto-conversion!)
        p1 = xrpc(agent, "app.bsky.actor.getProfile"; actor = "bsky.app")
        p2 = xrpc(agent, nsid"app.bsky.actor.getProfile"; actor = handle"bsky.app")
        p3 = xrpc(agent, API.App.Bsky.Actor.GetProfile.ENDPOINT; actor = did"did:plc:z72i7hdynmk6r22z27h6tvur")
        p4 = xrpc(agent, API.App.Bsky.Actor.GetProfile; actor = "bsky.app")
        p5 = get_profile(agent, handle"bsky.app")
        @test p1 == p2 == p3 == p4 == p5
        @test p1 isa API.AppBskyActorDefsProfileViewDetailed
        @test p1.did == did"did:plc:z72i7hdynmk6r22z27h6tvur"
        @test p1.handle == handle"bsky.app"
        @test p1.displayName == "Bluesky"
        @test seen[1].method == "GET"
        @test seen[1].url == "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=bsky.app"

        # Rate-limit tracking
        rl = rate_limit(agent)
        @test rl isa RateLimitInfo
        @test rl.limit == 3000
        @test rl.remaining == 2999
        @test rl.reset == 1700000000
        @test rl.policy == "3000;w=300"

        # Structured XRPCError
        err = try
            get_post_thread(agent, at"at://bsky.app/app.bsky.feed.post/3jui7kd54zh2y")
            nothing
        catch e
            e
        end
        @test err isa XRPCError
        @test err.status == 400
        @test err.error == "NotFound"
        @test err.message == "Post not found"
        @test occursin("NotFound", sprint(showerror, err))

        # Validation & bad dispatch checks
        @test_throws KeyError xrpc(agent, "com.example.doesNotExist")
        @test_throws ArgumentError xrpc(agent, API.Com.Atproto.Sync.SubscribeRepos)
        @test_throws ArgumentError xrpc(agent, ATProto.Syntax)
    end

    @testset "Session lifecycle, PDS routing, redaction & callbacks" begin
        events = Tuple{Symbol, Union{Session, Nothing}}[]
        seen = Any[]

        transport = function (method, url, headers, body; timeout)
            push!(seen, (method = method, url = url, headers = headers, body = body))
            if endswith(url, "/xrpc/com.atproto.server.createSession")
                return _json_resp(200, Dict(
                    "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                    "handle" => "alice.bsky.social",
                    "accessJwt" => "secret-access-jwt-1",
                    "refreshJwt" => "secret-refresh-jwt-1",
                    "email" => "alice@example.com",
                    "active" => true,
                    "didDoc" => Dict(
                        "id" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                        "service" => [
                            Dict(
                                "id" => "#atproto_pds",
                                "type" => "AtprotoPersonalDataServer",
                                "serviceEndpoint" => "https://morel.us-east.host.bsky.network/",
                            ),
                        ],
                    ),
                ))
            elseif endswith(url, "/xrpc/com.atproto.server.getSession")
                return _json_resp(200, Dict(
                    "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                    "handle" => "alice.bsky.social",
                    "active" => true,
                ))
            elseif endswith(url, "/xrpc/com.atproto.server.deleteSession")
                @test _hdr(headers, "Authorization") == "Bearer secret-refresh-jwt-1"
                return HTTP.Response(200)
            elseif occursin("/xrpc/app.bsky.feed.getTimeline", url)
                return _json_resp(200, Dict("feed" => Any[]))
            end
            return HTTP.Response(404)
        end

        agent = AtpAgent(
            "https://bsky.social/";
            on_session_change = (ev, s) -> push!(events, (ev, s)),
            transport = transport,
        )

        s = login!(agent, "alice.bsky.social", "app-pass-1234")
        @test is_authenticated(agent)
        @test session(agent) == s
        @test s.did == did"did:plc:z72i7hdynmk6r22z27h6tvur"
        @test s.handle == handle"alice.bsky.social"
        @test s.email == "alice@example.com"
        @test _hdr(seen[1].headers, "Authorization") === nothing

        # PDS endpoint extracted from didDoc (trailing slash stripped)
        @test service_url(agent) == "https://morel.us-east.host.bsky.network"

        # Subsequent authenticated request routes to PDS with Bearer accessJwt
        tl = get_timeline(agent; limit = 10)
        @test isempty(tl.feed)
        @test startswith(seen[2].url, "https://morel.us-east.host.bsky.network/xrpc/app.bsky.feed.getTimeline")
        @test _hdr(seen[2].headers, "Authorization") == "Bearer secret-access-jwt-1"

        # JWTs must NEVER appear in show() output
        s_repr = sprint(show, s)
        a_repr = sprint(show, agent)
        @test !occursin("secret-access-jwt-1", s_repr)
        @test !occursin("secret-refresh-jwt-1", s_repr)
        @test !occursin("secret-access-jwt-1", a_repr)
        @test !occursin("secret-refresh-jwt-1", a_repr)
        @test occursin("alice.bsky.social", a_repr)

        # logout! calls deleteSession with refreshJwt and resets PDS URL
        logout!(agent)
        @test !is_authenticated(agent)
        @test session(agent) === nothing
        @test service_url(agent) == "https://bsky.social"
        @test [ev for (ev, _) in events] == [:create, :delete]

        # resume_session! verifies via getSession
        resumed = resume_session!(agent, s)
        @test is_authenticated(agent)
        @test resumed.did == s.did
        @test service_url(agent) == "https://morel.us-east.host.bsky.network"
        @test events[end][1] == :resume
    end

    @testset "Automatic ExpiredToken refresh (HTTP 400 & 401) & single-flight concurrency" begin
        for err_status in (400, 401)
            refresh_calls = Ref(0)
            events = Symbol[]
            current_valid_access = Ref("jwt-v2")

            transport = function (method, url, headers, body; timeout)
                auth = _hdr(headers, "Authorization")
                if endswith(url, "/xrpc/com.atproto.server.refreshSession")
                    @test auth == "Bearer refresh-v1"
                    sleep(0.05) # force overlap across concurrent tasks
                    refresh_calls[] += 1
                    return _json_resp(200, Dict(
                        "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                        "handle" => "alice.bsky.social",
                        "accessJwt" => current_valid_access[],
                        "refreshJwt" => "refresh-v2",
                    ))
                elseif occursin("/xrpc/app.bsky.feed.getTimeline", url)
                    if auth == "Bearer jwt-v1"
                        return _json_resp(err_status, Dict("error" => "ExpiredToken", "message" => "Token has expired"))
                    elseif auth == "Bearer jwt-v2"
                        return _json_resp(200, Dict("feed" => Any[]))
                    end
                    return _json_resp(401, Dict("error" => "InvalidToken", "message" => "Bad token"))
                end
                return HTTP.Response(404)
            end

            agent = AtpAgent(
                "https://pds.example";
                on_session_change = (ev, _) -> push!(events, ev),
                transport = transport,
            )
            resume_session!(
                agent,
                Session(
                    did = "did:plc:z72i7hdynmk6r22z27h6tvur",
                    handle = "alice.bsky.social",
                    access_jwt = "jwt-v1",
                    refresh_jwt = "refresh-v1",
                );
                verify = false,
            )

            # Launch 4 concurrent requests that all initially fail with ExpiredToken
            tasks = [@async get_timeline(agent) for _ in 1:4]
            results = fetch.(tasks)
            @test length(results) == 4
            @test all(r -> r isa API.AppBskyFeedGetTimelineOutput, results)
            # Single-flight lock ensures refreshSession was called ONLY ONCE!
            @test refresh_calls[] == 1
            @test session(agent).access_jwt == "jwt-v2"
            @test session(agent).refresh_jwt == "refresh-v2"
            @test count(==(:refresh), events) == 1
        end

        # Refresh failure clears session and emits :expired
        expired_events = Symbol[]
        fail_transport = function (method, url, headers, body; timeout)
            if endswith(url, "/xrpc/com.atproto.server.refreshSession")
                return _json_resp(400, Dict("error" => "ExpiredToken", "message" => "Refresh token expired"))
            end
            return _json_resp(400, Dict("error" => "ExpiredToken", "message" => "Access token expired"))
        end
        agent = AtpAgent("https://pds.example"; on_session_change = (ev, _) -> push!(expired_events, ev), transport = fail_transport)
        resume_session!(agent, Session(did = "did:plc:abc", handle = "a.bsky.social", access_jwt = "a1", refresh_jwt = "r1"); verify = false)
        @test_throws XRPCError get_timeline(agent)
        @test !is_authenticated(agent)
        @test :expired in expired_events
    end

    @testset "Proxy, labelers & shared session views" begin
        captured = Any[]
        transport = function (method, url, headers, body; timeout)
            push!(captured, headers)
            if endswith(url, "/xrpc/com.atproto.server.refreshSession")
                return _json_resp(200, Dict(
                    "did" => "did:plc:abc",
                    "handle" => "a.bsky.social",
                    "accessJwt" => "fresh-jwt",
                    "refreshJwt" => "fresh-refresh",
                ))
            end
            return _json_resp(200, Dict("did" => "did:plc:abc", "handle" => "a.bsky.social"))
        end

        base_agent = AtpAgent("https://pds.example"; transport)
        resume_session!(base_agent, Session(did = "did:plc:abc", handle = "a.bsky.social", access_jwt = "old-jwt", refresh_jwt = "old-refresh"); verify = false)

        chat_agent = with_proxy(base_agent, "did:web:api.bsky.chat#bsky_chat")
        labeled_agent = with_labelers(chat_agent, ["did:plc:labeler1", "did:plc:labeler2"])

        get_profile(labeled_agent, "a.bsky.social")
        @test _hdr(captured[end], "atproto-proxy") == "did:web:api.bsky.chat#bsky_chat"
        @test _hdr(captured[end], "atproto-accept-labelers") == "did:plc:labeler1, did:plc:labeler2"

        # Refreshing via child view updates the shared session visible on base_agent!
        refresh_session!(labeled_agent)
        @test session(base_agent).access_jwt == "fresh-jwt"
        @test session(chat_agent).access_jwt == "fresh-jwt"
    end

    @testset "Repo CRUD helpers, post! & binary blob upload/download" begin
        seen = Any[]
        fake_png = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

        transport = function (method, url, headers, body; timeout)
            push!(seen, (method = method, url = url, headers = headers, body = body))
            if endswith(url, "/xrpc/com.atproto.repo.uploadBlob")
                @test _hdr(headers, "Content-Type") == "image/png"
                @test body == fake_png
                return _json_resp(200, Dict(
                    "blob" => Dict(
                        "\$type" => "blob",
                        "ref" => Dict("\$link" => "bafkrei123"),
                        "mimeType" => "image/png",
                        "size" => length(fake_png),
                    ),
                ))
            elseif occursin("/xrpc/com.atproto.sync.getBlob", url)
                return HTTP.Response(200, ["Content-Type" => "image/png"]; body = fake_png)
            elseif endswith(url, "/xrpc/com.atproto.repo.createRecord")
                payload = JSON.parse(String(body), Dict{String, Any})
                @test payload["repo"] == "did:plc:z72i7hdynmk6r22z27h6tvur"
                @test payload["collection"] == "app.bsky.feed.post"
                @test payload["record"]["\$type"] == "app.bsky.feed.post"
                @test payload["record"]["text"] == "Hello from Julia!"
                return _json_resp(200, Dict(
                    "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y",
                    "cid" => "bafyreipost1",
                ))
            elseif occursin("/xrpc/com.atproto.repo.getRecord", url)
                return _json_resp(200, Dict(
                    "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y",
                    "cid" => "bafyreipost1",
                    "value" => Dict(
                        "\$type" => "app.bsky.feed.post",
                        "text" => "Hello from Julia!",
                        "createdAt" => "2026-11-19T22:00:00Z",
                    ),
                ))
            elseif endswith(url, "/xrpc/com.atproto.repo.deleteRecord")
                return _json_resp(200, Dict())
            end
            return HTTP.Response(404)
        end

        agent = AtpAgent("https://pds.example"; transport)
        resume_session!(
            agent,
            Session(did = "did:plc:z72i7hdynmk6r22z27h6tvur", handle = "alice.bsky.social", access_jwt = "tok", refresh_jwt = "ref");
            verify = false,
        )

        # Binary upload
        up = upload_blob(agent, fake_png, "image/png")
        @test up.blob == BlobRef(ref = CIDLink("bafkrei123"), mimeType = "image/png", size = length(fake_png))

        # Binary download
        downloaded = xrpc(agent, API.Com.Atproto.Sync.GetBlob; did = did"did:plc:z72i7hdynmk6r22z27h6tvur", cid = "bafkrei123")
        @test downloaded == fake_png

        # post! helper
        created = post!(agent, "Hello from Julia!"; langs = ["en"])
        @test created.uri == at"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"
        @test created.cid == "bafyreipost1"

        # get_record by AtUri
        rec = get_record(agent, created.uri)
        @test rec.value isa API.AppBskyFeedPost
        @test rec.value.text == "Hello from Julia!"

        # delete_record by AtUri
        del = delete_record(agent, created.uri)
        @test del isa API.ComAtprotoRepoDeleteRecordOutput
    end

    @testset "Cursor pagination (eachpage & eachitem)" begin
        function make_feed_item(idx::Int)
            return Dict(
                "post" => Dict(
                    "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh$(lpad(idx, 2, 'a'))",
                    "cid" => "bafyrei$idx",
                    "author" => Dict("did" => "did:plc:z72i7hdynmk6r22z27h6tvur", "handle" => "bsky.app"),
                    "record" => Dict(
                        "\$type" => "app.bsky.feed.post",
                        "text" => "Post #$idx",
                        "createdAt" => "2026-11-19T22:00:00Z",
                    ),
                    "indexedAt" => "2026-11-19T22:00:01Z",
                ),
            )
        end

        calls = Ref(0)
        transport = function (method, url, headers, body; timeout)
            calls[] += 1
            if !occursin("cursor=", url)
                return _json_resp(200, Dict("cursor" => "c2", "feed" => [make_feed_item(1), make_feed_item(2)]))
            elseif occursin("cursor=c2", url)
                # Empty intermediate page with a valid next cursor — must skip seamlessly!
                return _json_resp(200, Dict("cursor" => "c3", "feed" => Any[]))
            elseif occursin("cursor=c3", url)
                return _json_resp(200, Dict("cursor" => "c4", "feed" => [make_feed_item(3), make_feed_item(4)]))
            elseif occursin("cursor=c4", url)
                # Repeated cursor — infinite loop guard must terminate!
                return _json_resp(200, Dict("cursor" => "c4", "feed" => [make_feed_item(5)]))
            end
            return HTTP.Response(404)
        end

        agent = AtpAgent(PUBLIC_APPVIEW; transport)

        # eachpage fetches all 4 pages then stops on repeated cursor
        pages = collect(eachpage(agent, "app.bsky.feed.getAuthorFeed"; actor = "bsky.app", limit = 2))
        @test length(pages) == 4
        @test eltype(pages) === API.AppBskyFeedGetAuthorFeedOutput

        # max_pages caps fetches
        calls[] = 0
        pages2 = collect(eachpage(agent, API.App.Bsky.Feed.GetAuthorFeed; actor = "bsky.app", max_pages = 2))
        @test length(pages2) == 2
        @test calls[] == 2

        # eachitem auto-infers :feed, skips empty page 2, returns tightly typed Vector!
        calls[] = 0
        all_items = collect(eachitem(agent, "app.bsky.feed.getAuthorFeed"; actor = "bsky.app"))
        @test eltype(all_items) === API.AppBskyFeedDefsFeedViewPost
        @test [it.post.record.text for it in all_items] == ["Post #1", "Post #2", "Post #3", "Post #4", "Post #5"]
        @test calls[] == 4

        # Laziness with Iterators.take: taking 2 items only fetches page 1!
        calls[] = 0
        first_two = collect(Iterators.take(eachitem(agent, API.App.Bsky.Feed.GetAuthorFeed; actor = "bsky.app"), 2))
        @test length(first_two) == 2
        @test calls[] == 1

        # Reject non-paginated endpoint
        @test_throws ArgumentError eachpage(agent, "app.bsky.actor.getProfile"; actor = "bsky.app")
    end

    @testset "End-to-end real HTTP loopback server" begin
        server = HTTP.serve!(Sockets.localhost, 0) do req::HTTP.Request
            if req.method == "GET" && startswith(req.target, "/xrpc/app.bsky.actor.getProfile")
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json", "RateLimit-Remaining" => "42"];
                    body = JSON.json(Dict(
                        "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                        "handle" => "loopback.test",
                    )),
                )
            elseif req.method == "POST" && req.target == "/xrpc/com.atproto.repo.createRecord"
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"];
                    body = JSON.json(Dict(
                        "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y",
                        "cid" => "bafyreiloopback",
                    )),
                )
            end
            return HTTP.Response(400, ["Content-Type" => "application/json"]; body = JSON.json(Dict("error" => "InvalidRequest", "message" => "Unknown path")))
        end

        try
            _, port = Sockets.getsockname(server.listener.server)
            agent = AtpAgent("http://127.0.0.1:$port")
            prof = get_profile(agent, "loopback.test")
            @test prof.handle == handle"loopback.test"
            @test rate_limit(agent).remaining == 42

            out = create_record(
                agent,
                API.App.Bsky.Feed.Post.Main(text = "loopback!", createdAt = "2026-11-19T22:00:00Z");
                repo = did"did:plc:z72i7hdynmk6r22z27h6tvur",
            )
            @test out.cid == "bafyreiloopback"
        finally
            close(server)
        end
    end
end
