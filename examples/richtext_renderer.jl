#!/usr/bin/env julia

#=
richtext_renderer.jl — Build Bluesky RichText posts and render facets to HTML & Markdown.

Demonstrates:
  - Programmatic `RichTextDoc` construction with exact 0-based UTF-8 byte offsets
  - Multi-byte emoji / Unicode grapheme handling
  - Rendering `segments(rt)` to safe escaped HTML and Markdown
  - Exact Bluesky JSON wire representation (`JSON.json`)

Usage:
  julia --project=. examples/richtext_renderer.jl
=#

using ATProto
using Dates
using JSON

function escape_html(s::AbstractString)
    return replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
end

function render_html(rt::RichTextDoc)
    io = IOBuffer()
    for seg in segments(rt)
        txt = escape_html(seg.text)
        if is_link(seg)
            print(io, "<a href=\"", escape_html(link_uri(seg)), "\">", txt, "</a>")
        elseif is_mention(seg)
            print(io, "<a href=\"https://bsky.app/profile/", mention_did(seg), "\">", txt, "</a>")
        elseif is_tag(seg)
            print(io, "<a href=\"https://bsky.app/hashtag/", escape_html(tag_value(seg)), "\">", txt, "</a>")
        else
            print(io, txt)
        end
    end
    return String(take!(io))
end

function render_markdown(rt::RichTextDoc)
    io = IOBuffer()
    for seg in segments(rt)
        if is_link(seg)
            print(io, "[", seg.text, "](", link_uri(seg), ")")
        elseif is_mention(seg)
            print(io, "[", seg.text, "](https://bsky.app/profile/", mention_did(seg), ")")
        elseif is_tag(seg)
            print(io, "[", seg.text, "](https://bsky.app/hashtag/", tag_value(seg), ")")
        else
            print(io, seg.text)
        end
    end
    return String(take!(io))
end

function main()
    # 1. Build a rich post with custom link labels & multi-byte emojis
    rt = RichTextDoc() do b
        add_text!(b, "🚀 Exploring ")
        add_link!(b, "ATProto.jl", "https://github.com/cell-scape/ATProto.jl")
        add_text!(b, " with ")
        add_mention!(b, "@bsky.app", did"did:plc:z72i7hdynmk6r22z27h6tvur")
        add_text!(b, " — built in ")
        add_tag!(b, "#JuliaLang")
        add_text!(b, "!")
    end

    println("Plain text : ", rt.text)
    println("Length     : ", grapheme_length(rt), " graphemes / ", byte_length(rt), " UTF-8 bytes")
    println("\nHTML       :\n  ", render_html(rt))
    println("\nMarkdown   :\n  ", render_markdown(rt))

    # 2. Wrap in a generated AppBskyFeedPost record and show exact wire JSON
    post = API.App.Bsky.Feed.Post.Main(
        text = rt.text,
        createdAt = String(ATDateTime(Dates.now(Dates.UTC))),
        facets = rt.facets,
        langs = ["en"],
    )
    println("\nWire JSON  :\n", JSON.json(post; pretty = true))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
