using Test
using ATProto
using ATProto.RichText
const RT = ATProto.RichText

@testset "UnicodeString" begin
    us = UnicodeString("hello")
    @test byte_length(us) == 5
    @test grapheme_length(us) == 5
    @test slice(us, 0, 5) == "hello"
    @test slice(us, 1, 3) == "el"

    # multi-byte: é (2 bytes), emoji 👨‍👩‍👧‍👧 (family, multiple graphemes-ish)
    unicode = UnicodeString("héllo")
    @test byte_length(unicode) == 6  # h + é(2) + l + l + o
    @test grapheme_length(unicode) == 5
    @test slice(unicode, 0, 3) == "hé"

    # emoji family is a single grapheme cluster with multiple codepoints
    fam = UnicodeString("👨‍👩‍👧‍👧")
    @test grapheme_length(fam) == 1
    @test byte_length(fam) == 25  # 4 emoji + 3 ZWJ = 7 × ~3.5 bytes

    # cjk
    cjk = UnicodeString("中文")
    @test byte_length(cjk) == 6
    @test grapheme_length(cjk) == 2
end

@testset "facet detection: mentions" begin
    # simple mention
    f = detect_facets(UnicodeString("start @handle.com end"))
    @test f !== nothing
    @test length(f) == 1
    @test f[1]["features"][1]["\$type"] == "app.bsky.richtext.facet#mention"
    @test f[1]["features"][1]["did"] == "handle.com"
    @test f[1]["index"]["byteStart"] == 6
    @test f[1]["index"]["byteEnd"] == 17  # 6 + 1(@) + 10(handle.com)

    # no mention without @
    @test detect_facets(UnicodeString("just plain text")) === nothing

    # multiple mentions
    f3 = detect_facets(UnicodeString("@a.com @b.com @c.com"))
    @test length(f3) == 3

    # invalid domain
    @test detect_facets(UnicodeString("not@right")) === nothing

    # .test domain
    ft = detect_facets(UnicodeString("@full123-chars.test"))
    @test ft !== nothing && ft[1]["features"][1]["did"] == "full123-chars.test"

    # parenthetical
    fp = detect_facets(UnicodeString("paren (@handle.com)"))
    @test fp !== nothing && length(fp) == 1

    # emoji before mention: byte offsets must be UTF-8 aware
    fe = detect_facets(UnicodeString("👨‍👩‍👧‍👧 @handle.com"))
    @test fe !== nothing
    @test fe[1]["index"]["byteStart"] == 25 + 1  # after the 25-byte family emoji + space
end

@testset "facet detection: links" begin
    f = detect_facets(UnicodeString("start https://middle.com end"))
    @test f !== nothing && length(f) == 1
    @test f[1]["features"][1]["uri"] == "https://middle.com"

    f2 = detect_facets(UnicodeString("start https://middle.com/foo/bar?baz=bux#hash end"))
    @test f2[1]["features"][1]["uri"] == "https://middle.com/foo/bar?baz=bux#hash"

    # bare domain gets https://
    f3 = detect_facets(UnicodeString("start middle.com end"))
    @test f3 !== nothing && length(f3) == 1
    @test f3[1]["features"][1]["uri"] == "https://middle.com"

    # trailing punctuation stripped
    f4 = detect_facets(UnicodeString("punctuation https://foo.com, https://bar.com/x; https://baz.com."))
    @test f4 !== nothing && length(f4) == 3
    @test f4[1]["features"][1]["uri"] == "https://foo.com"
    @test f4[2]["features"][1]["uri"] == "https://bar.com/x"
    @test f4[3]["features"][1]["uri"] == "https://baz.com"

    # unbalanced closing paren stripped
    f5 = detect_facets(UnicodeString("parenthetical (https://foo.com)"))
    @test f5[1]["features"][1]["uri"] == "https://foo.com"

    # not a URL
    @test detect_facets(UnicodeString("not.. a..url ..here")) === nothing
    @test detect_facets(UnicodeString("e.g.")) === nothing
end

@testset "facet detection: tags and cashtags" begin
    f = detect_facets(UnicodeString("#hello world"))
    @test f !== nothing
    @test f[1]["features"][1]["\$type"] == "app.bsky.richtext.facet#tag"
    @test f[1]["features"][1]["tag"] == "hello"

    f2 = detect_facets(UnicodeString("a #tag with more"))
    @test f2 !== nothing && length(f2) == 1
    @test f2[1]["features"][1]["tag"] == "tag"

    # cashtag
    f3 = detect_facets(UnicodeString("buy \$AAPL now"))
    @test f3 !== nothing && length(f3) == 1
    @test f3[1]["features"][1]["tag"] == "\$AAPL"

    # tag with trailing punctuation stripped
    f4 = detect_facets(UnicodeString("a #tag, and more"))
    @test f4[1]["features"][1]["tag"] == "tag"

    # no digit-only tags
    @test detect_facets(UnicodeString("#123")) === nothing
end

@testset "RichText insert/delete" begin
    rt = RT.RichText("hello world",
        facets = [Dict{String,Any}(
            "\$type" => "app.bsky.richtext.facet",
            "index" => Dict("byteStart" => 6, "byteEnd" => 11),
            "features" => [Dict("\$type" => "app.bsky.richtext.facet#tag",
                                "tag" => "world")])])

    # insert before: both shift
    insert_text!(rt, 0, "XX ")
    @test string(rt) == "XX hello world"
    @test rt.facets[1]["index"]["byteStart"] == 9
    @test rt.facets[1]["index"]["byteEnd"] == 14

    # insert inner (at byte 10, between 'w' and 'o' in world): end extends
    insert_text!(rt, 9, "YYY")
    @test string(rt) == "XX hello YYYworld"
    @test rt.facets[1]["index"]["byteEnd"] == 17

    # delete entirely outer: facet removed
    rt2 = RT.RichText("hello world",
        facets = [Dict{String,Any}(
            "\$type" => "app.bsky.richtext.facet",
            "index" => Dict("byteStart" => 6, "byteEnd" => 11),
            "features" => [Dict("\$type" => "app.bsky.richtext.facet#tag",
                                "tag" => "world")])])
    delete_text!(rt2, 0, 11)
    @test string(rt2) == ""
    @test rt2.facets === nothing

    # delete entirely before: both shift down
    rt3 = RT.RichText("hello world",
        facets = [Dict{String,Any}(
            "\$type" => "app.bsky.richtext.facet",
            "index" => Dict("byteStart" => 6, "byteEnd" => 11),
            "features" => [Dict("\$type" => "app.bsky.richtext.facet#tag",
                                "tag" => "world")])])
    delete_text!(rt3, 0, 6)
    @test string(rt3) == "world"
    @test rt3.facets[1]["index"]["byteStart"] == 0
    @test rt3.facets[1]["index"]["byteEnd"] == 5
end

@testset "RichText segments" begin
    rt = RT.RichText("check @handle.com and https://example.com/page")
    detect_facets_without_resolution!(rt)
    segs = segments(rt)
    @test length(segs) >= 3
    @test is_mention(segs[2])
    @test facet_mention(segs[2])["did"] == "handle.com"
    @test is_link(segs[end - 1]) || is_link(segs[4])
    # reconstruct the full text from segments
    @test join(string(s) for s in segs) == string(rt)
end

@testset "sanitize newlines" begin
    rt = RT.RichText("a\n\n\n\nb")
    sanitize_richtext!(rt)
    @test string(rt) == "a\n\nb"

    rt2 = RT.RichText("a\n\nb")
    sanitize_richtext!(rt2)
    @test string(rt2) == "a\n\nb"
end

@testset "detection with agent (mention resolution)" begin
    using HTTP
    fetch(method, url, headers, body; timeout = 30.0) =
        HTTP.Response(200, ["Content-Type" => "application/json"],
                      Vector{UInt8}(codeunits(
                          """{"did": "did:plc:ewvi7nx4oun5hl7s6yqkgcto"}""")))
    agent = Agent(; service = "https://pds.example.com", fetch)
    f = detect_facets(UnicodeString("hi @handle.com"); agent = agent)
    @test f !== nothing
    @test f[1]["features"][1]["did"] == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
end
