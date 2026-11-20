using ATProto
using ATProto.API
using ATProto.Client
using ATProto.RichText
using ATProto.Syntax
using HTTP
using JSON
using Test

@testset "RichText & Facets" begin
    @testset "UTF-8 byte length, grapheme length & byte_slice" begin
        # Emoji (4 bytes, 1 grapheme), accented char (2 bytes, 1 grapheme), ZWJ family emoji (1 grapheme, many bytes)
        txt = "🚀 café 👨‍👩‍👧‍👦"
        @test byte_length(txt) == ncodeunits(txt)
        @test grapheme_length(txt) == 8 # 🚀, ' ', c, a, f, é, ' ', family
        @test byte_slice(txt, 0, 4) == "🚀"
        @test byte_slice(txt, 5, 10) == "café"
    end

    @testset "Mention detection (handles, punctuation & email exclusion)" begin
        txt = "Hey @bsky.app and (@Alice.Bsky.Social), email bob@example.com or @notahandle!"
        mentions = detect_mentions(txt)
        @test length(mentions) == 2

        @test mentions[1].handle == handle"bsky.app"
        @test byte_slice(txt, mentions[1].byteStart, mentions[1].byteEnd) == "@bsky.app"

        @test mentions[2].handle == handle"alice.bsky.social"
        @test byte_slice(txt, mentions[2].byteStart, mentions[2].byteEnd) == "@Alice.Bsky.Social"

        # Multi-byte UTF-8 prefix before mention
        emoji_txt = "🎉 Hello @bsky.app!"
        em = detect_mentions(emoji_txt)
        @test length(em) == 1
        @test em[1].byteStart == 11 # 4 (🎉) + 7 (" Hello ")
        @test byte_slice(emoji_txt, em[1].byteStart, em[1].byteEnd) == "@bsky.app"
    end

    @testset "Link detection (schemes, bare domains, balanced parens & trailing punct)" begin
        txt = "See (https://en.wikipedia.org/wiki/Julia_(programming_language)), julialang.org/docs! Also not.local or v1.2."
        links = detect_links(txt)
        @test length(links) == 2

        @test links[1].uri == "https://en.wikipedia.org/wiki/Julia_(programming_language)"
        @test byte_slice(txt, links[1].byteStart, links[1].byteEnd) ==
              "https://en.wikipedia.org/wiki/Julia_(programming_language)"

        @test links[2].uri == "https://julialang.org/docs"
        @test byte_slice(txt, links[2].byteStart, links[2].byteEnd) == "julialang.org/docs"

        # URL with fragment should not generate a spurious hashtag in detect_facets
        url_frag = "Docs: https://atproto.com/specs/lexicon#datetime #atproto"
        facets = detect_facets(url_frag)
        @test length(facets) == 2
        @test facets[1].features[1] isa API.AppBskyRichtextFacetLink
        @test facets[1].features[1].uri == "https://atproto.com/specs/lexicon#datetime"
        @test facets[2].features[1] isa API.AppBskyRichtextFacetTag
        @test facets[2].features[1].tag == "atproto"
    end

    @testset "Hashtag detection (Unicode, punctuation, numeric & length limits)" begin
        txt = "Love #JuliaLang, ＃日本語! Skip #123, #., #..., and #" * "a"^65
        tags = detect_tags(txt)
        @test length(tags) == 2

        @test tags[1].tag == "JuliaLang"
        @test byte_slice(txt, tags[1].byteStart, tags[1].byteEnd) == "#JuliaLang"

        @test tags[2].tag == "日本語"
        @test byte_slice(txt, tags[2].byteStart, tags[2].byteEnd) == "＃日本語"
    end

    @testset "detect_facets with Dict resolver & AtpAgent handle resolution (deduplicated)" begin
        txt = "🚀 @bsky.app check https://julialang.org @bsky.app @unknown.invalid #JuliaLang!"

        # Offline Dict resolver
        d = Dict(handle"bsky.app" => did"did:plc:z72i7hdynmk6r22z27h6tvur")
        rt_offline = richtext(txt; resolve_handle = d)
        @test length(rt_offline.facets) == 4 # 2 mentions + 1 link + 1 tag
        @test [f.index.byteStart for f in rt_offline.facets] ==
              sort([f.index.byteStart for f in rt_offline.facets])

        # Live AtpAgent resolver via mock transport (deduplicates @bsky.app!)
        resolve_calls = Ref(0)
        transport = function (method, url, headers, body; timeout)
            resolve_calls[] += 1
            if occursin("handle=bsky.app", url)
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"];
                    body = JSON.json(Dict("did" => "did:plc:z72i7hdynmk6r22z27h6tvur")),
                )
            end
            return HTTP.Response(
                400,
                ["Content-Type" => "application/json"];
                body = JSON.json(Dict("error" => "InvalidRequest", "message" => "Unable to resolve handle")),
            )
        end
        agent = AtpAgent(PUBLIC_APPVIEW; transport)
        rt = richtext(agent, txt)
        @test rt == rt_offline
        # Only 2 RPCs (bsky.app once despite appearing twice + unknown.invalid once)
        @test resolve_calls[] == 2
    end

    @testset "RichTextBuilder, segments & post!(agent, rt)" begin
        rt = RichTextDoc() do b
            add_text!(b, "Hello 🌍 ")
            add_link!(b, "Julia", "https://julialang.org")
            add_text!(b, " ")
            add_mention!(b, "@bsky.app", did"did:plc:z72i7hdynmk6r22z27h6tvur")
            add_text!(b, " ")
            add_tag!(b, "#atproto")
        end

        @test rt.text == "Hello 🌍 Julia @bsky.app #atproto"
        @test length(rt.facets) == 3

        segs = segments(rt)
        @test join(s.text for s in segs) == rt.text
        @test length(segs) == 6
        @test !is_link(segs[1]) && segs[1].text == "Hello 🌍 "
        @test is_link(segs[2]) && link_uri(segs[2]) == "https://julialang.org" && segs[2].text == "Julia"
        @test is_mention(segs[4]) && mention_did(segs[4]) == did"did:plc:z72i7hdynmk6r22z27h6tvur" && segs[4].text == "@bsky.app"
        @test is_tag(segs[6]) && tag_value(segs[6]) == "atproto" && segs[6].text == "#atproto"

        # Publish RichTextDoc via post!(agent, rt) and verify exact JSON facets on wire!
        captured = Ref{Any}(nothing)
        transport = function (method, url, headers, body; timeout)
            captured[] = JSON.parse(String(body), Dict{String, Any})
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"];
                body = JSON.json(Dict(
                    "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y",
                    "cid" => "bafyreirt1",
                )),
            )
        end
        agent = AtpAgent("https://pds.example"; transport)
        resume_session!(
            agent,
            Session(did = "did:plc:z72i7hdynmk6r22z27h6tvur", handle = "bsky.app", access_jwt = "t", refresh_jwt = "r");
            verify = false,
        )
        out = post!(agent, rt; langs = ["en"])
        @test out.cid == "bafyreirt1"
        rec = captured[]["record"]
        @test rec["text"] == rt.text
        @test length(rec["facets"]) == 3
        @test rec["facets"][1]["features"][1]["\$type"] == "app.bsky.richtext.facet#link"
        @test rec["facets"][1]["index"]["byteStart"] == 11 # "Hello " (6) + "🌍" (4) + " " (1)
        @test rec["facets"][1]["index"]["byteEnd"] == 16   # + "Julia" (5)
        @test rec["facets"][2]["features"][1]["\$type"] == "app.bsky.richtext.facet#mention"
        @test rec["facets"][3]["features"][1]["\$type"] == "app.bsky.richtext.facet#tag"
        @test rec["facets"][3]["features"][1]["tag"] == "atproto"
    end
end
