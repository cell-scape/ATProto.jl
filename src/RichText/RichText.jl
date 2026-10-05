module RichText

using ..Syntax
using ..API
using ..XRPC
using HTTP

export UnicodeString,
    slice,
    RichText,
    RichTextSegment,
    detect_facets,
    detect_facets_without_resolution!,
    sanitize_richtext!,
    insert_text!,
    delete_text!,
    segments,
    facet_link,
    facet_mention,
    facet_tag,
    is_link,
    is_mention,
    is_tag,
    grapheme_length,
    byte_length,
    clone,
    detect_facets

include("unicode.jl")
include("detection.jl")
include("richtext.jl")

end # module
