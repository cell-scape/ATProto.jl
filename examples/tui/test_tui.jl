#!/usr/bin/env julia

#=
Headless verification suite for BlueskyTUI using Tachikoma.TestBackend and
a mock-transport AtpAgent (zero live network requests required).

Run:
  julia --project=examples/tui examples/tui/test_tui.jl
=#

const _REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
if !(_REPO_ROOT in LOAD_PATH)
    push!(LOAD_PATH, _REPO_ROOT)
end

using Dates
using JSON
using Test
using ATProto
using Tachikoma

include(joinpath(@__DIR__, "BlueskyTUI.jl"))
using .BlueskyTUI

# ── Helpers ─────────────────────────────────────────────────────────

function render_model(m::BlueskyModel; width::Int = 120, height::Int = 36)
    tb = TestBackend(width, height)
    f = Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[])
    Tachikoma.view(m, f)
    return tb
end

function drain_until!(m::BlueskyModel, predicate::Function; timeout_s::Float64 = 30.0)
    deadline = time() + timeout_s
    while time() < deadline
        drain_tasks!(m.queue) do tevt
            Tachikoma.update!(m, tevt)
        end
        predicate() && return true
        sleep(0.01)
    end
    drain_tasks!(m.queue) do tevt
        Tachikoma.update!(m, tevt)
    end
    return predicate()
end

function type_string!(m::BlueskyModel, s::AbstractString)
    for ch in s
        Tachikoma.update!(m, KeyEvent(ch))
    end
end

function _json_response(obj; status::Int = 200)
    body = Vector{UInt8}(JSON.json(obj))
    headers = [
        "Content-Type" => "application/json",
        "RateLimit-Limit" => "3000",
        "RateLimit-Remaining" => "2995",
    ]
    return ATProto.Client.HTTP.Response(status, headers, body)
end

function _sample_post_json(;
    uri = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2la",
    cid = "bafyreihash1",
    did = "did:plc:z72i7hdynmk6r22z27h6tvur",
    handle = "bsky.app",
    display_name = "Bluesky",
    text = "Hello @alice.bsky.social! Check https://julialang.org #JuliaLang",
    facets = Any[
        Dict(
            "index" => Dict("byteStart" => 6, "byteEnd" => 24),
            "features" => Any[Dict("\$type" => "app.bsky.richtext.facet#mention", "did" => "did:plc:alice12345678901234567890")],
        ),
        Dict(
            "index" => Dict("byteStart" => 32, "byteEnd" => 53),
            "features" => Any[Dict("\$type" => "app.bsky.richtext.facet#link", "uri" => "https://julialang.org")],
        ),
        Dict(
            "index" => Dict("byteStart" => 54, "byteEnd" => 64),
            "features" => Any[Dict("\$type" => "app.bsky.richtext.facet#tag", "tag" => "JuliaLang")],
        ),
    ],
    embed = Dict(
        "\$type" => "app.bsky.embed.external#view",
        "external" => Dict(
            "uri" => "https://julialang.org",
            "title" => "The Julia Programming Language",
            "description" => "Fast, dynamic, open-source language.",
        ),
    ),
    likes = 42,
    reposts = 7,
    replies = 3,
    viewer = Dict{String, Any}(),
)
    d = Dict{String, Any}(
        "uri" => uri,
        "cid" => cid,
        "author" => Dict(
            "did" => did,
            "handle" => handle,
            "displayName" => display_name,
        ),
        "record" => Dict(
            "\$type" => "app.bsky.feed.post",
            "text" => text,
            "facets" => facets,
            "langs" => ["en"],
            "createdAt" => "2026-04-12T12:00:00.000Z",
        ),
        "indexedAt" => "2026-04-12T12:00:01.000Z",
        "likeCount" => likes,
        "repostCount" => reposts,
        "replyCount" => replies,
        "quoteCount" => 1,
        "viewer" => viewer,
    )
    !isnothing(embed) && (d["embed"] = embed)
    return d
end

function build_mock_agent(; authenticated::Bool = false)
    recorded_calls = Tuple{String, String}[]

    transport = function (method, url, headers, body; timeout = 30.0)
        push!(recorded_calls, (method, url))
        if occursin("app.bsky.feed.getAuthorFeed", url)
            if occursin("cursor=page2", url)
                return _json_response(Dict(
                    "feed" => Any[
                        Dict("post" => _sample_post_json(
                            uri = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2page2",
                            cid = "bafyreipage2",
                            text = "Second page post via cursor pagination!",
                            facets = Any[],
                            embed = nothing,
                            likes = 9,
                        )),
                    ],
                ))
            else
                return _json_response(Dict(
                    "cursor" => "page2",
                    "feed" => Any[
                        Dict(
                            "post" => _sample_post_json(),
                            "reason" => Dict("\$type" => "app.bsky.feed.defs#reasonPin"),
                        ),
                        Dict(
                            "post" => _sample_post_json(
                                uri = "at://did:plc:alice12345678901234567890/app.bsky.feed.post/3k2img",
                                cid = "bafyreiimg",
                                did = "did:plc:alice12345678901234567890",
                                handle = "alice.bsky.social",
                                display_name = "Alice",
                                text = "Look at this sunset photo!",
                                facets = Any[],
                                embed = Dict(
                                    "\$type" => "app.bsky.embed.images#view",
                                    "images" => Any[Dict(
                                        "thumb" => "https://cdn.example/thumb.jpg",
                                        "fullsize" => "https://cdn.example/full.jpg",
                                        "alt" => "Golden sunset over mountains",
                                        "aspectRatio" => Dict("width" => 1600, "height" => 900),
                                    )],
                                ),
                                likes = 1200,
                            ),
                            "reason" => Dict(
                                "\$type" => "app.bsky.feed.defs#reasonRepost",
                                "by" => Dict("did" => "did:plc:z72i7hdynmk6r22z27h6tvur", "handle" => "bsky.app"),
                                "indexedAt" => "2026-04-12T12:05:00.000Z",
                            ),
                        ),
                    ],
                ))
            end
        elseif occursin("app.bsky.feed.getTimeline", url)
            return _json_response(Dict(
                "feed" => Any[
                    Dict("post" => _sample_post_json(
                        uri = "at://did:plc:alice12345678901234567890/app.bsky.feed.post/3k2tl",
                        cid = "bafyreitl",
                        handle = "alice.bsky.social",
                        display_name = "Alice",
                        text = "Welcome to your authenticated Home Timeline!",
                        facets = Any[],
                        embed = nothing,
                    )),
                ],
            ))
        elseif occursin("app.bsky.feed.searchPosts", url)
            return _json_response(Dict(
                "posts" => Any[
                    _sample_post_json(
                        uri = "at://did:plc:bob1234567890123456789012/app.bsky.feed.post/3k2srch",
                        cid = "bafyreisrch",
                        did = "did:plc:bob1234567890123456789012",
                        handle = "bob.example.com",
                        display_name = "Bob",
                        text = "Julia ATProto TUI search hit!",
                        facets = Any[],
                        embed = nothing,
                    ),
                ],
            ))
        elseif occursin("app.bsky.feed.getPostThread", url)
            return _json_response(Dict(
                "thread" => Dict(
                    "\$type" => "app.bsky.feed.defs#threadViewPost",
                    "post" => _sample_post_json(),
                    "parent" => Dict(
                        "\$type" => "app.bsky.feed.defs#threadViewPost",
                        "post" => _sample_post_json(
                            uri = "at://did:plc:parent123456789012345678/app.bsky.feed.post/3k2par",
                            cid = "bafyreipar",
                            did = "did:plc:parent123456789012345678",
                            handle = "parent.bsky.social",
                            display_name = "Parent Author",
                            text = "Original ancestor post in thread",
                            facets = Any[],
                            embed = nothing,
                        ),
                    ),
                    "replies" => Any[
                        Dict(
                            "\$type" => "app.bsky.feed.defs#threadViewPost",
                            "post" => _sample_post_json(
                                uri = "at://did:plc:reply1234567890123456789/app.bsky.feed.post/3k2rep",
                                cid = "bafyreirep",
                                did = "did:plc:reply1234567890123456789",
                                handle = "replier.bsky.social",
                                display_name = "Replier",
                                text = "Great reply right here!",
                                facets = Any[],
                                embed = nothing,
                            ),
                            "replies" => Any[],
                        ),
                    ],
                ),
            ))
        elseif occursin("app.bsky.actor.getProfile", url)
            return _json_response(Dict(
                "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                "handle" => "bsky.app",
                "displayName" => "Bluesky Official",
                "description" => "Official account. Visit https://bsky.social #ATProto",
                "avatar" => "https://cdn.example/avatar.jpg",
                "banner" => "https://cdn.example/banner.jpg",
                "followersCount" => 12_500_000,
                "followsCount" => 15,
                "postsCount" => 842,
                "createdAt" => "2023-04-12T00:00:00.000Z",
            ))
        elseif occursin("app.bsky.notification.listNotifications", url)
            return _json_response(Dict(
                "notifications" => Any[
                    Dict(
                        "uri" => "at://did:plc:alice12345678901234567890/app.bsky.feed.like/3k2nf1",
                        "cid" => "bafynf1",
                        "author" => Dict("did" => "did:plc:alice12345678901234567890", "handle" => "alice.bsky.social", "displayName" => "Alice"),
                        "reason" => "like",
                        "reasonSubject" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2la",
                        "record" => Dict("\$type" => "app.bsky.feed.like", "createdAt" => "2026-04-12T12:02:00.000Z",
                                         "subject" => Dict("uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2la", "cid" => "bafyreihash1")),
                        "isRead" => false,
                        "indexedAt" => "2026-04-12T12:02:01.000Z",
                    ),
                    Dict(
                        "uri" => "at://did:plc:bob1234567890123456789012/app.bsky.graph.follow/3k2nf2",
                        "cid" => "bafynf2",
                        "author" => Dict("did" => "did:plc:bob1234567890123456789012", "handle" => "bob.example.com", "displayName" => "Bob"),
                        "reason" => "follow",
                        "record" => Dict("\$type" => "app.bsky.graph.follow", "createdAt" => "2026-04-12T12:01:00.000Z",
                                         "subject" => "did:plc:me123456789012345678901234"),
                        "isRead" => true,
                        "indexedAt" => "2026-04-12T12:01:01.000Z",
                    ),
                ],
            ))
        elseif occursin("app.bsky.notification.getUnreadCount", url)
            return _json_response(Dict("count" => 3))
        elseif occursin("app.bsky.notification.updateSeen", url)
            return _json_response(Dict())
        elseif occursin("app.bsky.actor.getPreferences", url)
            return _json_response(Dict(
                "preferences" => Any[Dict(
                    "\$type" => "app.bsky.actor.defs#savedFeedsPrefV2",
                    "items" => Any[
                        Dict("id" => "sf1", "pinned" => true, "type" => "timeline", "value" => "following"),
                        Dict("id" => "sf2", "pinned" => true, "type" => "feed", "value" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot"),
                    ],
                )],
            ))
        elseif occursin("app.bsky.feed.getFeedGenerators", url)
            return _json_response(Dict(
                "feeds" => Any[Dict(
                    "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot",
                    "cid" => "bafygen1",
                    "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                    "creator" => Dict("did" => "did:plc:z72i7hdynmk6r22z27h6tvur", "handle" => "bsky.app"),
                    "displayName" => "Discover Hot",
                    "indexedAt" => "2026-04-12T00:00:00.000Z",
                )],
            ))
        elseif occursin("app.bsky.feed.getFeed", url)
            return _json_response(Dict(
                "feed" => Any[Dict("post" => _sample_post_json(
                    uri = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2hot",
                    cid = "bafyhot",
                    text = "Trending post inside Discover Hot feed!",
                    facets = Any[],
                    embed = nothing,
                ))],
            ))
        elseif occursin("app.bsky.graph.getLists", url)
            return _json_response(Dict("lists" => Any[]))
        elseif occursin("app.bsky.bookmark.getBookmarks", url)
            return _json_response(Dict(
                "bookmarks" => Any[Dict(
                    "subject" => Dict("uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2la", "cid" => "bafyreihash1"),
                    "item" => _sample_post_json(text = "Saved bookmark post!"),
                )],
            ))
        elseif occursin("app.bsky.bookmark.createBookmark", url) || occursin("app.bsky.bookmark.deleteBookmark", url)
            return _json_response(Dict())
        elseif occursin("app.bsky.graph.muteActor", url) || occursin("app.bsky.graph.unmuteActor", url)
            return _json_response(Dict())
        elseif occursin("chat.bsky.convo.listConvos", url)
            return _json_response(Dict(
                "convos" => Any[Dict(
                    "id" => "convo-42",
                    "rev" => "rev1",
                    "muted" => false,
                    "unreadCount" => 1,
                    "members" => Any[
                        Dict("did" => "did:plc:me123456789012345678901234", "handle" => "tester.bsky.social", "displayName" => "Tester"),
                        Dict("did" => "did:plc:alice12345678901234567890", "handle" => "alice.bsky.social", "displayName" => "Alice"),
                    ],
                )],
            ))
        elseif occursin("chat.bsky.convo.getMessages", url)
            return _json_response(Dict(
                "messages" => Any[Dict(
                    "\$type" => "chat.bsky.convo.defs#messageView",
                    "id" => "m1",
                    "rev" => "r1",
                    "text" => "Hey! Loving the CRT TUI!",
                    "sender" => Dict("did" => "did:plc:alice12345678901234567890"),
                    "sentAt" => "2026-04-12T12:03:00.000Z",
                )],
            ))
        elseif occursin("chat.bsky.convo.sendMessage", url)
            parsed = JSON.parse(String(body), Dict{String, Any})
            return _json_response(Dict(
                "\$type" => "chat.bsky.convo.defs#messageView",
                "id" => "m2",
                "rev" => "r2",
                "text" => parsed["message"]["text"],
                "sender" => Dict("did" => "did:plc:me123456789012345678901234"),
                "sentAt" => "2026-04-12T12:04:00.000Z",
            ))
        elseif occursin("chat.bsky.convo.updateRead", url)
            return _json_response(Dict(
                "convo" => Dict(
                    "id" => "convo-42",
                    "rev" => "r2",
                    "muted" => false,
                    "unreadCount" => 0,
                    "members" => Any[
                        Dict("did" => "did:plc:alice12345678901234567890", "handle" => "alice.bsky.social"),
                    ],
                ),
            ))
        elseif occursin("com.atproto.identity.resolveHandle", url)
            return _json_response(Dict("did" => "did:plc:alice12345678901234567890"))
        elseif occursin("com.atproto.repo.createRecord", url)
            parsed = JSON.parse(String(body), Dict{String, Any})
            col = get(parsed, "collection", "app.bsky.feed.like")
            return _json_response(Dict(
                "uri" => "at://did:plc:me123456789012345678901234/$col/3k2new",
                "cid" => "bafyreinew",
            ))
        elseif occursin("com.atproto.repo.deleteRecord", url)
            return _json_response(Dict())
        else
            return _json_response(Dict("error" => "NotFound", "message" => "Unhandled URL: $url"); status = 404)
        end
    end

    agent = AtpAgent(PUBLIC_APPVIEW; transport = transport)
    if authenticated
        sess = Session(
            did = DID("did:plc:me123456789012345678901234"),
            handle = Handle("tester.bsky.social"),
            access_jwt = "mock-access-jwt",
            refresh_jwt = "mock-refresh-jwt",
        )
        resume_session!(agent, sess; verify = false)
    end
    return agent, recorded_calls
end

# Mock iterable Jetstream stream for Tab 4 tests
mutable struct MockJetstreamStream
    ch::Channel{Any}
    cursor::Union{Int64, Nothing}
    closed::Bool
end

function MockJetstreamStream(events)
    ch = Channel{Any}(64)
    for ev in events
        put!(ch, ev)
    end
    close(ch)
    return MockJetstreamStream(ch, Int64(1_744_459_200_000_000), false)
end

Base.iterate(s::MockJetstreamStream, state = nothing) = iterate(s.ch)
ATProto.Jetstream.last_cursor(s::MockJetstreamStream) = s.cursor
Base.close(s::MockJetstreamStream) = (s.closed = true; isopen(s.ch) && close(s.ch); nothing)

# ── Test Suite ──────────────────────────────────────────────────────

@testset "BlueskyTUI Headless Tests" begin
    @testset "Formatting & RichText Span Rendering" begin
        ref = DateTime(2026, 4, 12, 12, 5, 0)
        @test BlueskyTUI.format_relative_time("2026-04-12T12:04:45.000Z"; ref = ref) == "15s"
        @test BlueskyTUI.format_relative_time("2026-04-12T12:00:00.000Z"; ref = ref) == "5m"
        @test BlueskyTUI.format_relative_time("2026-04-12T09:05:00.000Z"; ref = ref) == "3h"
        @test BlueskyTUI.format_relative_time("2026-04-10T12:05:00.000Z"; ref = ref) == "2d"

        @test BlueskyTUI.format_count(42) == "42"
        @test BlueskyTUI.format_count(1_500) == "1.5K"
        @test BlueskyTUI.format_count(2_400_000) == "2.4M"
        @test BlueskyTUI.format_count(nothing) == "0"

        rt = richtext("Hi https://julialang.org\n#JuliaLang")
        lines = BlueskyTUI.richtext_to_span_lines(rt.text, rt.facets)
        @test length(lines) == 2
        link_spans = filter(s -> s.style.hyperlink == "https://julialang.org", lines[1])
        @test length(link_spans) == 1
        @test link_spans[1].content == "https://julialang.org"
        tag_spans = filter(s -> s.content == "#JuliaLang", lines[2])
        @test length(tag_spans) == 1
        @test tag_spans[1].style.hyperlink == "https://bsky.app/hashtag/JuliaLang"

        # Forward-compatible UnknownObject embed never crashes
        unk = UnknownObject("com.example.futureEmbed", Dict{String, Any}("foo" => 1))
        ulines = BlueskyTUI.embed_to_span_lines(unk)
        @test length(ulines) == 1
        @test occursin("com.example.futureEmbed", ulines[1][1].content)
    end

function mock_identity_resolver(did::DID)
    vm = ATProto.Identity.DIDVerificationMethod(
        "#atproto",
        "Multikey",
        string(did),
        "zQ3shMockSigningKey1234567890",
    )
    doc = ATProto.Identity.DIDDocument(
        did,
        ["at://bsky.app"],
        [vm],
        ATProto.Identity.DIDService[],
        Dict{String, Any}(),
    )
    return ATProto.Identity.ResolvedIdentity(
        did,
        Handle("bsky.app"),
        "https://morel.us-east.host.bsky.network",
        vm,
        doc,
        true,
    )
end

    @testset "Feed, Detail, Pagination, Thread, Profile & Modals" begin
        agent, calls = build_mock_agent(; authenticated = false)
        m = BlueskyModel(;
            agent = agent,
            initial_actor = "bsky.app",
            auto_fetch = false,
            auto_timer = false,
            auto_login = false,
            identity_resolver = mock_identity_resolver,
        )

        # Trigger initial feed load and verify async TaskEvent delivery
        BlueskyTUI._fetch_feed!(m; append = false)
        @test drain_until!(m, () -> length(m.feed_entries) == 2)

        tb = render_model(m)
        @test find_text(tb, "BSKY·DECK") !== nothing
        @test find_text(tb, "AT-5150") !== nothing
        @test find_text(tb, "PVM-14") !== nothing
        @test find_text(tb, "TRK 01/02") !== nothing
        @test find_text(tb, "◉ BRT") !== nothing
        @test find_text(tb, "bsky.app") !== nothing
        @test find_text(tb, "The Julia Programming Language") !== nothing
        @test find_text(tb, "42 likes") !== nothing
        @test find_text(tb, "RL:2995/3000") !== nothing
        @test Tachikoma.copy_rect(m) == m.rect_feed_list

        # Mouse click on multi-line card #2 selects post #2 directly
        card2_y = m.rect_feed_cards_inner.y + BlueskyTUI.FEED_CARD_STRIDE
        Tachikoma.update!(m, MouseEvent(m.rect_feed_cards_inner.x + 4, card2_y, mouse_left, mouse_press, false, false, false))
        @test m.feed_list.selected == 2
        Tachikoma.update!(m, KeyEvent('k'))
        @test m.feed_list.selected == 1

        # Navigate down to post #2 (image embed + repost badge)
        Tachikoma.update!(m, KeyEvent('j'))
        @test m.feed_list.selected == 2
        tb2 = render_model(m)
        @test find_text(tb2, "TRK 02/02") !== nothing
        @test find_text(tb2, "Images (1)") !== nothing
        @test find_text(tb2, "Golden sunset over mountains") !== nothing
        @test find_text(tb2, "1.2K likes") !== nothing

        # Switch focus to detail pane via Tab -> copy_rect follows focus
        Tachikoma.update!(m, KeyEvent(:tab))
        @test m.feed_focus === :detail
        @test Tachikoma.copy_rect(m) == m.rect_feed_detail
        Tachikoma.update!(m, KeyEvent(:left))
        @test m.feed_focus === :list

        # Cursor pagination via 'n'
        Tachikoma.update!(m, KeyEvent('n'))
        @test drain_until!(m, () -> length(m.feed_entries) == 3)
        @test m.feed_cursor === nothing

        # Open Thread tab via Enter on post 1
        Tachikoma.update!(m, KeyEvent(:home))
        @test m.feed_list.selected == 1
        Tachikoma.update!(m, KeyEvent(:enter))
        @test m.tabs.active == BlueskyTUI.TAB_THREAD
        @test drain_until!(m, () -> length(m.thread_posts) == 3)
        tb_th = render_model(m)
        @test find_text(tb_th, "VT-AT220") !== nothing
        @test find_text(tb_th, "╰═══╦═══╯") !== nothing
        @test find_text(tb_th, "Parent Context") !== nothing
        @test find_text(tb_th, "Original ancestor post") !== nothing
        @test find_text(tb_th, "Great reply right here!") !== nothing

        # Esc returns from Thread to Feed
        Tachikoma.update!(m, KeyEvent(:escape))
        @test m.tabs.active == BlueskyTUI.TAB_FEED

        # Profile tab via 'o' (uses mock_identity_resolver -> instant verified badge!)
        Tachikoma.update!(m, KeyEvent('o'))
        @test m.tabs.active == BlueskyTUI.TAB_PROFILE
        @test drain_until!(m, () -> !isnothing(m.profile_data) && !isnothing(m.profile_identity))
        tb_prof = render_model(m)
        @test find_text(tb_prof, "IBM-3270") !== nothing
        @test find_text(tb_prof, "ID VERIFIED") !== nothing
        @test find_text(tb_prof, "╰═══╦═══╯") !== nothing
        @test find_text(tb_prof, "Bluesky Official") !== nothing
        @test find_text(tb_prof, "12.5M") !== nothing
        @test find_text(tb_prof, "Verified") !== nothing
        @test find_text(tb_prof, "morel.us-east.host.bsky.network") !== nothing
        @test find_text(tb_prof, "zQ3shMockSigningKey") !== nothing

        # Press 'f' in Profile tab to load author's feed & switch to Tab 1
        Tachikoma.update!(m, KeyEvent('f'))
        @test m.tabs.active == BlueskyTUI.TAB_FEED
        @test drain_until!(m, () -> m.feed_mode === :author && !isempty(m.feed_entries))

        # Go-To-Actor modal validation ('g')
        Tachikoma.update!(m, KeyEvent('g'))
        @test m.modal === :goto
        type_string!(m, "not a handle!")
        tb_bad = render_model(m)
        @test find_text(tb_bad, "Invalid handle or DID") !== nothing
        set_text!(m.goto_input, "bsky.app")
        tb_ok = render_model(m)
        @test find_text(tb_ok, "Valid handle") !== nothing
        Tachikoma.update!(m, KeyEvent(:escape))
        @test m.modal === :none

        # Search modal ('/')
        Tachikoma.update!(m, KeyEvent('/'))
        @test m.modal === :search
        type_string!(m, "JuliaLang")
        Tachikoma.update!(m, KeyEvent(:enter))
        @test m.modal === :none
        @test m.feed_mode === :search
        @test drain_until!(m, () -> !isempty(m.feed_entries) && occursin("search hit", m.feed_entries[1].post.record.text))
        tb_srch = render_model(m)
        @test find_text(tb_srch, "Julia ATProto TUI search hit!") !== nothing

        # Compose modal ('c') — live grapheme/byte counter + facet preview + read-only dry-run
        Tachikoma.update!(m, KeyEvent('c'))
        @test m.modal === :compose
        type_string!(m, "Hi @bsky.app https://julialang.org #JuliaLang 🚀")
        tb_cmp = render_model(m)
        @test find_text(tb_cmp, "47/300 gr") !== nothing
        @test find_text(tb_cmp, "1 mentions") !== nothing
        @test find_text(tb_cmp, "1 links") !== nothing
        @test find_text(tb_cmp, "1 tags") !== nothing
        Tachikoma.update!(m, KeyEvent(:ctrl, 'd'))
        @test m.modal === :none
        @test occursin("Dry-run Post OK", m.status_msg)

        # Login modal ('L') — password must NEVER appear in plaintext in rendered buffer!
        Tachikoma.update!(m, KeyEvent('L'))
        @test m.modal === :login
        type_string!(m, "tester.bsky.social")
        Tachikoma.update!(m, KeyEvent(:tab))
        type_string!(m, "super-secret-app-pw")
        tb_login = render_model(m)
        @test find_text(tb_login, "tester.bsky.social") !== nothing
        @test find_text(tb_login, "super-secret-app-pw") === nothing
        @test find_text(tb_login, "•••••") !== nothing
        Tachikoma.update!(m, KeyEvent(:escape))
        @test m.modal === :none

        # Help overlay ('?')
        Tachikoma.update!(m, KeyEvent('?'))
        @test m.modal === :help
        tb_help = render_model(m)
        @test find_text(tb_help, "Keybindings") !== nothing
        Tachikoma.update!(m, KeyEvent(:escape))
        @test m.modal === :none

        # CRT toggles: scanlines ('v'), ambient DotWave ('b'), and Phosphor cycle ('P')
        @test m.scanlines == true
        Tachikoma.update!(m, KeyEvent('v'))
        @test m.scanlines == false
        Tachikoma.update!(m, KeyEvent('v'))
        @test m.scanlines == true

        @test m.ambient_bg == true
        Tachikoma.update!(m, KeyEvent('b'))
        @test m.ambient_bg == false
        Tachikoma.update!(m, KeyEvent('b'))
        @test m.ambient_bg == true

        old_th = theme()
        old_lm = light_mode()
        Tachikoma.update!(m, KeyEvent('P'))
        tb_ph = render_model(m)
        @test find_text(tb_ph, "BSKY·DECK") !== nothing
        set_light_mode!(old_lm)
        set_theme!(old_th)

        # Live theme switch triggers automatic re-theme without crash
        set_theme!(DRACULA)
        tb_th2 = render_model(m)
        @test m.last_theme_name == DRACULA.name
        @test find_text(tb_th2, "ATProto.jl") !== nothing
        set_theme!(old_th)

        # Quit ('q')
        Tachikoma.update!(m, KeyEvent('q'))
        @test Tachikoma.should_quit(m)
        Tachikoma.cleanup!(m)
    end

    @testset "Authenticated Actions (Timeline, Like, Repost, Publish)" begin
        agent, calls = build_mock_agent(; authenticated = true)
        m = BlueskyModel(;
            agent = agent,
            initial_actor = "bsky.app",
            auto_fetch = false,
            auto_timer = false,
            auto_login = false,
        )
        BlueskyTUI._fetch_feed!(m; append = false)
        @test drain_until!(m, () -> length(m.feed_entries) == 2)

        # Like post #1
        @test m.feed_entries[1].post.likeCount == 42
        Tachikoma.update!(m, KeyEvent('l'))
        @test drain_until!(m, () -> m.feed_entries[1].post.likeCount == 43)
        @test !isnothing(m.feed_entries[1].post.viewer.like)

        # Unlike post #1
        Tachikoma.update!(m, KeyEvent('l'))
        @test drain_until!(m, () -> m.feed_entries[1].post.likeCount == 42)
        @test isnothing(m.feed_entries[1].post.viewer.like)

        # Repost post #1
        Tachikoma.update!(m, KeyEvent('R'))
        @test drain_until!(m, () -> m.feed_entries[1].post.repostCount == 8)

        # Toggle Home Timeline ('T')
        Tachikoma.update!(m, KeyEvent('T'))
        @test m.feed_mode === :timeline
        @test drain_until!(m, () -> length(m.feed_entries) == 1 && occursin("Home Timeline", m.feed_entries[1].post.record.text))

        # Reply ('p') and publish with Ctrl+D
        Tachikoma.update!(m, KeyEvent('p'))
        @test m.modal === :compose
        @test !isnothing(m.compose_reply_to)
        type_string!(m, "Replying from Tachikoma TUI! #JuliaLang")
        Tachikoma.update!(m, KeyEvent(:ctrl, 'd'))
        @test m.modal === :none
        @test drain_until!(m, () -> occursin("Reply published", m.status_msg))

        tb_auth = render_model(m)
        @test find_text(tb_auth, "@tester.bsky.social") !== nothing

        # Quote-post ('Q') and publish
        Tachikoma.update!(m, KeyEvent('Q'))
        @test m.modal === :compose
        @test !isnothing(m.compose_quote_of)
        tb_q = render_model(m)
        @test find_text(tb_q, "Quote @alice.bsky.social") !== nothing
        type_string!(m, "Quoting from the CRT deck!")
        Tachikoma.update!(m, KeyEvent(:ctrl, 'd'))
        @test m.modal === :none
        @test drain_until!(m, () -> occursin("Quote-post published", m.status_msg))

        # Bookmark toggle ('B')
        Tachikoma.update!(m, KeyEvent('B'))
        @test drain_until!(m, () -> !isempty(m.bookmarked_uris))
        tb_bm = render_model(m)
        @test find_text(tb_bm, "SAVED") !== nothing

        # Saved Feeds & Bookmarks switcher ('s') -> switch to Discover Hot feed
        Tachikoma.update!(m, KeyEvent('s'))
        @test drain_until!(m, () -> m.modal === :feeds && length(m.saved_feeds) >= 3)
        tb_sf = render_model(m)
        @test find_text(tb_sf, "Discover Hot") !== nothing
        # Move down to item 3 (Discover Hot) and press Enter
        Tachikoma.update!(m, KeyEvent('j'))
        Tachikoma.update!(m, KeyEvent('j'))
        Tachikoma.update!(m, KeyEvent(:enter))
        @test m.modal === :none
        @test m.feed_mode === :saved_feed
        @test drain_until!(m, () -> !isempty(m.feed_entries) && occursin("Discover Hot", m.feed_entries[1].post.record.text))

        # Load author feed again and inspect image alt-text gallery ('i') on post #2
        m.feed_mode = :author
        BlueskyTUI._fetch_feed!(m; append = false)
        @test drain_until!(m, () -> length(m.feed_entries) == 2)
        Tachikoma.update!(m, KeyEvent('j'))
        Tachikoma.update!(m, KeyEvent('i'))
        @test m.modal === :gallery
        @test length(m.gallery_images) == 1
        tb_gal = render_model(m)
        @test find_text(tb_gal, "Golden sunset over mountains") !== nothing
        @test find_text(tb_gal, "1600×900") !== nothing
        Tachikoma.update!(m, KeyEvent(:escape))
        @test m.modal === :none

        # Profile Follow ('F') & Mute ('M') & Profile Media Gallery ('i')
        Tachikoma.update!(m, KeyEvent('o'))
        @test m.tabs.active == BlueskyTUI.TAB_PROFILE
        @test drain_until!(m, () -> !isnothing(m.profile_data))
        Tachikoma.update!(m, KeyEvent('F'))
        @test drain_until!(m, () -> !isnothing(m.profile_data.viewer) && !isnothing(m.profile_data.viewer.following))
        Tachikoma.update!(m, KeyEvent('M'))
        @test drain_until!(m, () -> !isnothing(m.profile_data.viewer) && something(m.profile_data.viewer.muted, false))
        Tachikoma.update!(m, KeyEvent('i'))
        @test m.modal === :gallery && length(m.gallery_images) == 2  # Avatar + Banner
        Tachikoma.update!(m, KeyEvent(:escape))

        # Notifications Tab ('4') — DEC-LA120, unread badge, mark seen ('m'), open thread ('Enter')
        Tachikoma.update!(m, KeyEvent('4'))
        @test m.tabs.active == BlueskyTUI.TAB_NOTIFS
        @test drain_until!(m, () -> length(m.notifs) == 2 && m.notifs_unread == 3)
        tb_nf = render_model(m)
        @test find_text(tb_nf, "DEC-LA120") !== nothing
        @test find_text(tb_nf, "3 UNREAD") !== nothing
        @test find_text(tb_nf, "alice.bsky.social") !== nothing
        Tachikoma.update!(m, KeyEvent('m'))
        @test drain_until!(m, () -> m.notifs_unread == 0)
        Tachikoma.update!(m, KeyEvent(:enter))
        @test m.tabs.active == BlueskyTUI.TAB_THREAD

        # Chat / DMs Tab ('5') — TTY-DM300 via with_proxy, read & send DM ('c')
        Tachikoma.update!(m, KeyEvent('5'))
        @test m.tabs.active == BlueskyTUI.TAB_CHAT
        @test drain_until!(m, () -> length(m.chat_convos) == 1 && length(m.chat_messages) == 1)
        tb_ch = render_model(m)
        @test find_text(tb_ch, "TTY-DM300") !== nothing
        @test find_text(tb_ch, "Loving the CRT TUI!") !== nothing
        Tachikoma.update!(m, KeyEvent('c'))
        @test m.modal === :chat_send
        type_string!(m, "Hello back from ATProto.jl!")
        Tachikoma.update!(m, KeyEvent(:enter))
        @test m.modal === :none
        @test drain_until!(m, () -> length(m.chat_messages) == 2)
        tb_ch2 = render_model(m)
        @test find_text(tb_ch2, "Hello back from ATProto.jl!") !== nothing

        Tachikoma.cleanup!(m)
    end

    @testset "Jetstream Firehose Tab & Sparkline" begin
        mock_events = [
            JetstreamCommitEvent(
                DID("did:plc:z72i7hdynmk6r22z27h6tvur"),
                Int64(1_744_459_200_000_000),
                "rev1",
                :create,
                NSID("app.bsky.feed.post"),
                RecordKey("3k2js1"),
                API.AppBskyFeedPost(
                    text = "Streaming live over Jetstream with #JuliaLang!",
                    createdAt = "2026-04-12T12:00:00.000Z",
                ),
                "bafyreij1",
            ),
            JetstreamCommitEvent(
                DID("did:plc:alice12345678901234567890"),
                Int64(1_744_459_201_000_000),
                "rev2",
                :create,
                NSID("app.bsky.feed.like"),
                RecordKey("3k2js2"),
                nothing,
                "bafyreij2",
            ),
        ]

        agent, _ = build_mock_agent(; authenticated = false)
        m = BlueskyModel(;
            agent = agent,
            initial_tab = BlueskyTUI.TAB_FIREHOSE,
            auto_fetch = false,
            auto_timer = false,
            auto_login = false,
            jetstream_connector = cols -> MockJetstreamStream(mock_events),
        )

        # Press Space to connect to mock Jetstream stream
        Tachikoma.update!(m, KeyEvent(' '))
        @test drain_until!(m, () -> m.firehose_total == 2)
        @test m.firehose_posts == 1
        @test m.firehose_likes == 1

        # Trigger 1-second timer tick -> updates Sparkline history
        Tachikoma.update!(m, TaskEvent(:tick_1s, time()))
        @test m.firehose_rate_history[end] == 2.0

        tb_fh = render_model(m)
        @test find_text(tb_fh, "JS-MODEM") !== nothing
        @test find_text(tb_fh, "TEK-4010") !== nothing
        @test find_text(tb_fh, "TTY-LIVE") !== nothing
        @test find_text(tb_fh, "Jetstream Firehose") !== nothing
        @test find_text(tb_fh, "Events / sec") !== nothing
        @test find_text(tb_fh, "Streaming live over Jetstream") !== nothing

        # Cycle preset ('C') and clear ('x')
        Tachikoma.update!(m, KeyEvent('C'))
        @test m.firehose_preset_idx == 2
        Tachikoma.update!(m, KeyEvent('x'))
        @test m.firehose_total == 0
        @test isempty(m.firehose_items)
        Tachikoma.cleanup!(m)
    end
end
