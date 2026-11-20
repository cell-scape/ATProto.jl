```@meta
CurrentModule = ATProto
DocTestSetup = quote
    using ATProto
end
```

# RichText & Facets

`ATProto.RichText` computes exact 0-based UTF-8 byte offsets for Bluesky
`app.bsky.richtext.facet` annotations (mentions, links, and hashtags), supports
deduplicated `AtpAgent` handle resolution, programmatic facet building via
`RichTextBuilder`, grapheme counting, and segment-based rendering.

## Examples

```jldoctest
julia> rt = RichTextDoc() do b
           add_text!(b, "Hello 🚀 ")
           add_link!(b, "Julia", "https://julialang.org")
           add_text!(b, " ")
           add_tag!(b, "#julialang")
       end;

julia> rt.text
"Hello 🚀 Julia #julialang"

julia> length(rt.facets)
2

julia> [(s.text, link_uri(s), tag_value(s)) for s in segments(rt)]
4-element Vector{Tuple{String, Any, Any}}:
 ("Hello 🚀 ", nothing, nothing)
 ("Julia", "https://julialang.org", nothing)
 (" ", nothing, nothing)
 ("#julialang", nothing, "julialang")
```

## Reference

```@autodocs
Modules = [ATProto.RichText]
Order = [:type, :function]
```
