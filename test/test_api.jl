using ATProto
using ATProto.API
using ATProto.Syntax
using JSON
using Test

@testset "Generated Lexicon API" begin
    @testset "Registry & endpoint completeness" begin
        @test length(LEXICON_ENDPOINTS) == 193
        @test length(LEXICON_TOKENS) == 31
        @test haskey(LEXICON_TYPES, "blob")
        @test LEXICON_TYPES["blob"] === BlobRef
        @test LEXICON_TYPES["app.bsky.feed.post"] === API.AppBskyFeedPost
        @test LEXICON_TYPES["app.bsky.feed.post#main"] === API.AppBskyFeedPost
        @test LEXICON_TYPES["app.bsky.embed.images#view"] === API.AppBskyEmbedImagesView

        # Namespace module aliases match canonical types & endpoints
        @test API.App.Bsky.Feed.Post.Main === API.AppBskyFeedPost
        @test API.App.Bsky.Feed.Post.ReplyRef === API.AppBskyFeedPostReplyRef
        @test API.App.Bsky.Feed.Defs.PostView === API.AppBskyFeedDefsPostView
        @test API.App.Bsky.Graph.Defs.Modlist == "app.bsky.graph.defs#modlist"
        @test API.Com.Atproto.Repo.CreateRecord.ENDPOINT === LEXICON_ENDPOINTS["com.atproto.repo.createRecord"]
        @test API.Com.Atproto.Repo.CreateRecord.Input === API.ComAtprotoRepoCreateRecordInput
        @test API.Com.Atproto.Repo.CreateRecord.Output === API.ComAtprotoRepoCreateRecordOutput
        @test API.App.Bsky.Actor.GetProfile.Output === API.AppBskyActorDefsProfileViewDetailed

        # Record metadata traits
        @test lexicon_type(API.AppBskyFeedPost) == "app.bsky.feed.post"
        @test needs_type_tag(API.AppBskyFeedPost) == true
        @test record_key_type(API.AppBskyFeedPost) == "tid"
        @test record_key_type(API.AppBskyActorProfile) == "literal:self"
        @test needs_type_tag(API.AppBskyEmbedImages) == true
        @test needs_type_tag(API.AppBskyEmbedDefsAspectRatio) == false
    end

    @testset "Post record, BlobRef, CIDLink & XRPC input round-trip" begin
        Post = API.App.Bsky.Feed.Post.Main
        Images = API.App.Bsky.Embed.Images.Main
        ImageItem = API.App.Bsky.Embed.Images.Image
        AspectRatio = API.App.Bsky.Embed.Defs.AspectRatio

        post = Post(
            text = "Hello Bluesky from ATProto.jl!",
            createdAt = "2026-11-19T18:40:00Z",
            langs = ["en"],
            embed = Images(images = [
                ImageItem(
                    image = BlobRef(
                        ref = CIDLink("bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
                        mimeType = "image/png",
                        size = 42000,
                    ),
                    alt = "Julia logo",
                    aspectRatio = AspectRatio(width = 800, height = 600),
                ),
            ]),
        )

        wire = JSON.json(post)
        raw = JSON.parse(wire, Dict{String, Any})
        @test raw["\$type"] == "app.bsky.feed.post"
        @test !haskey(raw, "reply") # omitted null optional field
        @test raw["embed"]["\$type"] == "app.bsky.embed.images"
        @test raw["embed"]["images"][1]["image"]["\$type"] == "blob"
        @test raw["embed"]["images"][1]["image"]["ref"]["\$link"] == "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
        @test !haskey(raw["embed"]["images"][1]["aspectRatio"], "\$type")

        # Round-trip through abstract LexiconObject dispatcher
        parsed = JSON.parse(wire, LexiconObject)
        @test parsed isa Post
        @test parsed == post
        @test hash(parsed) == hash(post)

        # XRPC Input message does NOT emit top-level $type, while embedded record DOES
        req = API.Com.Atproto.Repo.CreateRecord.Input(
            repo = "bsky.app",
            collection = "app.bsky.feed.post",
            rkey = "3jui7kd54zh2y",
            record = post,
        )
        @test req.collection == nsid"app.bsky.feed.post"
        @test req.rkey == rkey"3jui7kd54zh2y"
        req_wire = JSON.json(req)
        req_raw = JSON.parse(req_wire, Dict{String, Any})
        @test !haskey(req_raw, "\$type")
        @test req_raw["record"]["\$type"] == "app.bsky.feed.post"

        req_rt = JSON.parse(req_wire, API.Com.Atproto.Repo.CreateRecord.Input)
        @test req_rt == req
        @test req_rt.record isa Post

        # Plain Dict converts to UnknownObject for `unknown` record fields
        custom_req = API.Com.Atproto.Repo.CreateRecord.Input(
            repo = "bsky.app",
            collection = "com.example.custom",
            record = Dict("\$type" => "com.example.custom", "score" => 99),
        )
        @test custom_req.record isa UnknownObject
        @test custom_req.record["score"] == 99
    end

    @testset "Open unions & UnknownObject fallback" begin
        Post = API.App.Bsky.Feed.Post.Main

        # Future unknown $type inside post.embed
        future_json = """{
            "\$type": "app.bsky.feed.post",
            "text": "check out this future embed",
            "createdAt": "2026-11-19T18:40:00Z",
            "embed": {
                "\$type": "com.future.hologram#main",
                "depth": 3,
                "label": "3d"
            }
        }"""
        p = JSON.parse(future_json, Post)
        @test p.embed isa UnknownObject
        @test lexicon_type(p.embed) == "com.future.hologram#main"
        @test p.embed["depth"] == 3
        @test haskey(p.embed, "label")
        @test get(p.embed, "missing", :none) === :none

        # Lossless round-trip of unknown object
        p_rt = JSON.parse(JSON.json(p), Post)
        @test p_rt == p

        # Mixed known + unknown + untyped elements in preferences vector
        prefs_json = """{
            "preferences": [
                {"\$type": "app.bsky.actor.defs#adultContentPref", "enabled": true},
                {"\$type": "com.future.pref", "alpha": 1},
                {"untyped": "value"}
            ]
        }"""
        prefs_out = JSON.parse(prefs_json, API.App.Bsky.Actor.GetPreferences.Output)
        @test length(prefs_out.preferences) == 3
        @test prefs_out.preferences[1] isa API.AppBskyActorDefsAdultContentPref
        @test prefs_out.preferences[1].enabled == true
        @test prefs_out.preferences[2] isa UnknownObject
        @test lexicon_type(prefs_out.preferences[2]) == "com.future.pref"
        @test prefs_out.preferences[3] isa UnknownObject
        @test lexicon_type(prefs_out.preferences[3]) === nothing
    end

    @testset "Cyclic struct deserialization (all 3 Lexicon SCCs)" begin
        # Cycle 1: ViewerState -> KnownFollowers -> ProfileViewBasic -> ViewerState (no $type on wire!)
        profile_json = """{
            "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
            "handle": "bsky.app",
            "viewer": {
                "muted": false,
                "knownFollowers": {
                    "count": 1,
                    "followers": [
                        {
                            "did": "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
                            "handle": "atproto.com",
                            "viewer": {
                                "muted": false
                            }
                        }
                    ]
                }
            }
        }"""
        prof = JSON.parse(profile_json, API.App.Bsky.Actor.Defs.ProfileViewDetailed)
        @test prof.did == did"did:plc:z72i7hdynmk6r22z27h6tvur"
        @test prof.handle == handle"bsky.app"
        @test prof.viewer isa API.AppBskyActorDefsViewerState
        @test prof.viewer.knownFollowers isa API.AppBskyActorDefsKnownFollowers
        @test prof.viewer.knownFollowers.count == 1
        @test prof.viewer.knownFollowers.followers[1].handle == handle"atproto.com"
        @test prof.viewer.knownFollowers.followers[1].viewer.muted == false
        @test JSON.parse(JSON.json(prof), API.App.Bsky.Actor.Defs.ProfileViewDetailed) == prof

        # Cycle 3: Self-recursive ThreadViewPost with nested replies + NotFoundPost
        thread_json = """{
            "thread": {
                "\$type": "app.bsky.feed.defs#threadViewPost",
                "post": {
                    "uri": "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y",
                    "cid": "bafyrei111",
                    "author": {
                        "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
                        "handle": "bsky.app"
                    },
                    "record": {
                        "\$type": "app.bsky.feed.post",
                        "text": "root post",
                        "createdAt": "2026-11-19T18:00:00Z"
                    },
                    "indexedAt": "2026-11-19T18:00:01Z"
                },
                "replies": [
                    {
                        "\$type": "app.bsky.feed.defs#notFoundPost",
                        "uri": "at://bsky.app/app.bsky.feed.post/3jui7kd54zh2z",
                        "notFound": true
                    }
                ]
            }
        }"""
        thread_out = JSON.parse(thread_json, API.App.Bsky.Feed.GetPostThread.Output)
        @test thread_out.thread isa API.AppBskyFeedDefsThreadViewPost
        @test thread_out.thread.post.uri == at"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"
        @test thread_out.thread.post.record isa API.AppBskyFeedPost
        @test thread_out.thread.post.record.text == "root post"
        @test thread_out.thread.replies[1] isa API.AppBskyFeedDefsNotFoundPost
        @test thread_out.thread.replies[1].notFound == true
    end

    @testset "Keyword field rename, zero-field singletons & ATBytes" begin
        # `end_` <-> JSON `"end"`
        ts = API.App.Bsky.Feed.Post.TextSlice(start = 0, end_ = 12)
        ts_json = JSON.json(ts)
        @test JSON.parse(ts_json, Dict{String, Any}) == Dict("start" => 0, "end" => 12)
        @test JSON.parse(ts_json, API.AppBskyFeedPostTextSlice) == ts

        # Zero-field structs serialize as JSON objects, never as Julia strings
        pin = API.App.Bsky.Feed.Defs.ReasonPin()
        @test JSON.json(pin) == "{\"\$type\":\"app.bsky.feed.defs#reasonPin\"}"
        @test JSON.parse(JSON.json(pin), LexiconObject) == pin

        empty_out = API.App.Bsky.Feed.SendInteractions.Output()
        @test JSON.json(empty_out) == "{}"
        @test JSON.parse("{}", API.AppBskyFeedSendInteractionsOutput) == empty_out

        # ATBytes + nullable `since` + CIDLink in ComAtprotoSyncSubscribeReposCommit
        commit = API.Com.Atproto.Sync.SubscribeRepos.Commit(
            seq = 100,
            rebase = false,
            tooBig = false,
            repo = did"did:plc:z72i7hdynmk6r22z27h6tvur",
            commit = CIDLink("bafyreiabc"),
            rev = tid"3jui7kd54zh2y",
            since = nothing,
            blocks = ATBytes(UInt8[0x01, 0x02, 0x03, 0x04, 0x05]),
            ops = [
                API.Com.Atproto.Sync.SubscribeRepos.RepoOp(
                    action = "delete",
                    path = "app.bsky.feed.post/3jui7kd54zh2y",
                    cid = nothing,
                ),
            ],
            blobs = CIDLink[],
            time = "2026-11-19T18:40:00Z",
        )
        c_wire = JSON.json(commit)
        c_rt = JSON.parse(c_wire, API.ComAtprotoSyncSubscribeReposCommit)
        @test c_rt == commit
        @test c_rt.blocks == ATBytes(UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
        @test c_rt.since === nothing
        @test c_rt.ops[1].cid === nothing

        # Typed syntax fields reject invalid inputs
        @test_throws SyntaxError API.Com.Atproto.Repo.StrongRef.Main(
            uri = "https://not-an-at-uri.com",
            cid = "bafyrei123",
        )
    end

    @testset "Code generator determinism" begin
        gen_mod = Module(:_CodegenTestMod)
        Base.include(gen_mod, joinpath(pkgdir(ATProto), "src", "codegen.jl"))
        mktempdir() do tmp
            stats = gen_mod.LexiconCodegen.generate_lexicons(lexicons_path(), tmp)
            @test stats.lexicons == 237
            @test stats.types == 553
            @test stats.cycle_breaks == 1
            for fname in ("types.jl", "registry.jl", "endpoints.jl", "namespaces.jl")
                expected = read(joinpath(pkgdir(ATProto), "src", "api", "generated", fname), String)
                actual = read(joinpath(tmp, fname), String)
                @test actual == expected
            end
        end
    end
end
