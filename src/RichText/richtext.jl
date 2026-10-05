# RichText: text + facets with insert/delete index adjustment.
# Port of `packages/api/src/rich-text/rich-text.ts`.

"""
    RichTextSegment

One rendered segment of a rich text: either a facet-covered slice or plain
text between facets.
"""
struct RichTextSegment
    text::String
    facet::Union{Dict{String,Any},Nothing}
end

RichTextSegment(text::AbstractString) = RichTextSegment(String(text), nothing)
Base.string(seg::RichTextSegment) = seg.text
Base.show(io::IO, seg::RichTextSegment) = print(io, seg.text)

"The link feature of a segment's facet, if any."
facet_link(seg::RichTextSegment) =
    seg.facet === nothing ? nothing :
    _find_feature(seg.facet, "app.bsky.richtext.facet#link")
is_link(seg::RichTextSegment) = facet_link(seg) !== nothing

"The mention feature of a segment's facet, if any."
facet_mention(seg::RichTextSegment) =
    seg.facet === nothing ? nothing :
    _find_feature(seg.facet, "app.bsky.richtext.facet#mention")
is_mention(seg::RichTextSegment) = facet_mention(seg) !== nothing

"The tag feature of a segment's facet, if any."
facet_tag(seg::RichTextSegment) =
    seg.facet === nothing ? nothing :
    _find_feature(seg.facet, "app.bsky.richtext.facet#tag")
is_tag(seg::RichTextSegment) = facet_tag(seg) !== nothing

function _find_feature(facet::Dict, type::String)
    for f in facet["features"]
        get(f, "\$type", "") == type && return f
    end
    return nothing
end

"""
    RichText(text; facets=nothing, clean_newlines=false)

A rich text: the text plus facets over UTF-8 byte ranges. Facets are sorted
and zero/negative-length ones filtered. Supports `insert`/`delete` with
facet index adjustment, detection, and segment iteration.
"""
mutable struct RichText
    unicode_text::UnicodeString
    facets::Union{Vector{Dict{String,Any}},Nothing}
end

RichText(text::AbstractString; facets = nothing,
         clean_newlines::Bool = false) =
    RichText(UnicodeString(text), facets === nothing ? nothing :
             _clean_facets(facets))

Base.string(rt::RichText) = rt.unicode_text.text
byte_length(rt::RichText) = byte_length(rt.unicode_text)
grapheme_length(rt::RichText) = grapheme_length(rt.unicode_text)

function _clean_facets(facets)
    cleaned = filter(facets) do f
        idx = f["index"]
        idx["byteStart"] <= idx["byteEnd"]
    end
    sort!(cleaned; by = f -> f["index"]["byteStart"])
    return isempty(cleaned) ? nothing : cleaned
end

"Deep copy of the facets."
function _clone_facets(facets)
    facets === nothing && return nothing
    return [deepcopy(f) for f in facets]
end

clone(rt::RichText) = RichText(rt.unicode_text, _clone_facets(rt.facets))

"""
    insert_text!(rt, insert_index, insert_text)

Insert text at a byte index, adjusting facet ranges:
before → shift both; inner → extend end; after → no-op.
"""
function insert_text!(rt::RichText, insert_index::Int, insert_text::AbstractString)
    s = rt.unicode_text.text
    insert_index += 1  # 0-based to 1-based
    rt.unicode_text = UnicodeString(string(slice(rt.unicode_text, 0, insert_index - 1),
                                             insert_text,
                                             slice(rt.unicode_text, insert_index - 1, byte_length(rt.unicode_text))))
    facets_local = rt.facets
    facets_local === nothing && return rt
    num_added = ncodeunits(insert_text)
    for f in facets_local
        idx = f["index"]
        if insert_index - 1 <= idx["byteStart"]
            idx["byteStart"] += num_added
            idx["byteEnd"] += num_added
        elseif insert_index - 1 < idx["byteEnd"]
            idx["byteEnd"] += num_added
        end
    end
    return rt
end

"""
    delete_text!(rt, remove_start, remove_end)

Delete `[remove_start, remove_end)` bytes, adjusting or removing facets
per the six overlap scenarios from the reference implementation.
"""
function delete_text!(rt::RichText, remove_start::Int, remove_end::Int)
    s = rt.unicode_text.text
    rt.unicode_text = UnicodeString(string(slice(rt.unicode_text, 0, remove_start),
                                            slice(rt.unicode_text, remove_end, byte_length(rt.unicode_text))))
    facets_local = rt.facets
    facets_local === nothing && return rt
    num_removed = remove_end - remove_start
    keep = Dict{String,Any}[]
    for f in facets_local
        idx = f["index"]
        bs, be = idx["byteStart"], idx["byteEnd"]
        if remove_start <= bs && remove_end >= be
            # A: entirely outer -> delete facet
            continue
        elseif remove_start > be
            # B: entirely after -> noop
        elseif remove_start > bs && remove_start <= be && remove_end > be
            # C: partially after -> truncate end
            idx["byteEnd"] = remove_start
        elseif remove_start >= bs && remove_end <= be
            # D: entirely inner -> shrink end
            idx["byteEnd"] -= num_removed
        elseif remove_start < bs && remove_end >= bs && remove_end <= be
            # E: partially before -> move start, shrink end
            idx["byteStart"] = remove_start
            idx["byteEnd"] -= num_removed
        elseif remove_end < bs
            # F: entirely before -> shift both
            idx["byteStart"] -= num_removed
            idx["byteEnd"] -= num_removed
        end
        idx["byteStart"] < idx["byteEnd"] && push!(keep, f)
    end
    rt.facets = isempty(keep) ? nothing : keep
    return rt
end

"""
    detect_facets_without_resolution!(rt)

Overwrite facets with auto-detected ones (mentions unresolved, tags, links,
cashtags).
"""
function detect_facets_without_resolution!(rt::RichText)
    rt.facets = detect_facets(rt.unicode_text)
    return rt
end

"""
    detect_facets(rt; agent)

Detect facets and resolve mention handles to DIDs via the agent.
"""
function detect_facets(rt::RichText; agent)
    rt.facets = detect_facets(rt.unicode_text; agent = agent)
    return rt
end

"""
    sanitize_richtext!(rt; clean_newlines=true)

Collapse 3+ newlines (with intervening whitespace) to double newlines.
"""
function sanitize_richtext!(rt::RichText; clean_newlines::Bool = true)
    clean_newlines || return rt
    excess = r"[\r\n]([\x00AD\x2060\x200D\x200C\x200B\s]*[\r\n]){2,}"
    while (m = match(excess, rt.unicode_text.text)) !== nothing
        remove_start = m.offset - 1
        remove_end = remove_start + ncodeunits(m.match)
        delete_text!(rt, remove_start, remove_end)
        insert_text!(rt, remove_start, "\n\n")
    end
    return rt
end

"""
    segments(rt) -> Vector{RichTextSegment}

Split the text into alternating plain/faceted segments.
"""
function segments(rt::RichText)::Vector{RichTextSegment}
    facets = rt.facets === nothing ? Dict{String,Any}[] : rt.facets
    isempty(facets) && return RichTextSegment[RichTextSegment(rt.unicode_text.text)]

    out = RichTextSegment[]
    text_cursor = 0
    facet_cursor = 1
    while facet_cursor <= length(facets)
        f = facets[facet_cursor]
        bs, be = f["index"]["byteStart"], f["index"]["byteEnd"]
        if text_cursor < bs
            push!(out, RichTextSegment(slice(rt.unicode_text, text_cursor, bs)))
        elseif text_cursor > bs
            facet_cursor += 1
            continue
        end
        if bs < be
            subtext = slice(rt.unicode_text, bs, be)
            if isempty(strip(subtext))
                push!(out, RichTextSegment(subtext))
            else
                push!(out, RichTextSegment(subtext, f))
            end
        end
        text_cursor = be
        facet_cursor += 1
    end
    if text_cursor < byte_length(rt)
        push!(out, RichTextSegment(slice(rt.unicode_text, text_cursor, byte_length(rt))))
    end
    return out
end
