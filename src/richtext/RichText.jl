module RichText

using Unicode

using ..Syntax: DID, Handle, is_valid_handle, is_valid_tld
using ..API: LexiconObject,
             AppBskyRichtextFacet,
             AppBskyRichtextFacetByteSlice,
             AppBskyRichtextFacetMention,
             AppBskyRichtextFacetLink,
             AppBskyRichtextFacetTag
using ..Client: AtpAgent, xrpc, XRPCError

export RichTextDoc, RichTextSegment, RichTextBuilder,
       add_text!, add_link!, add_mention!, add_tag!, build,
       grapheme_length, byte_length, byte_slice,
       detect_mentions, detect_links, detect_tags, detect_facets, richtext,
       segments, is_mention, is_link, is_tag, mention_did, link_uri, tag_value

# -----------------------------------------------------------------------------
# Core types
# -----------------------------------------------------------------------------

"""
    RichTextDoc(text::AbstractString, facets=AppBskyRichtextFacet[])
    RichTextDoc(f::Function)

AT Protocol rich text document pairing UTF-8 `text` with zero-indexed UTF-8 byte
span `facets` (`app.bsky.richtext.facet`).

Use the `do`-block form to construct rich text programmatically with exact UTF-8
byte offsets:
```julia
rt = RichTextDoc() do b
    add_text!(b, "Hello 🚀 ")
    add_link!(b, "Julia", "https://julialang.org")
    add_text!(b, " ")
    add_tag!(b, "#julialang")
end
```
"""
struct RichTextDoc
    text::String
    facets::Vector{AppBskyRichtextFacet}
end

function RichTextDoc(
    text::AbstractString,
    facets::AbstractVector{AppBskyRichtextFacet} = AppBskyRichtextFacet[],
)
    sorted = sort(collect(facets); by = f -> (f.index.byteStart, f.index.byteEnd))
    return RichTextDoc(String(text), sorted)
end

Base.:(==)(a::RichTextDoc, b::RichTextDoc) = a.text == b.text && a.facets == b.facets
Base.hash(a::RichTextDoc, h::UInt) = hash(a.facets, hash(a.text, hash(:RichTextDoc, h)))
Base.String(rt::RichTextDoc) = rt.text
Base.print(io::IO, rt::RichTextDoc) = print(io, rt.text)

"""
    byte_length(x) -> Int

Return the UTF-8 byte length (`ncodeunits`) of a string or [`RichTextDoc`](@ref).
Bluesky posts have a 3000-byte maximum.
"""
byte_length(s::AbstractString) = ncodeunits(s)
byte_length(rt::RichTextDoc) = ncodeunits(rt.text)

"""
    grapheme_length(x) -> Int

Return the Unicode extended grapheme cluster count of a string or [`RichTextDoc`](@ref).
Bluesky posts have a 300-grapheme maximum.
"""
grapheme_length(s::AbstractString) = length(Unicode.graphemes(s))
grapheme_length(rt::RichTextDoc) = length(Unicode.graphemes(rt.text))

"""
    byte_slice(text::AbstractString, byte_start::Integer, byte_end::Integer) -> String

Extract the substring corresponding to an AT Protocol 0-based UTF-8 byte slice
`[byte_start, byte_end)` (start inclusive, end exclusive).
"""
function byte_slice(text::AbstractString, byte_start::Integer, byte_end::Integer)
    s = String(text)
    n = ncodeunits(s)
    lo = clamp(Int(byte_start), 0, n)
    hi = clamp(Int(byte_end), lo, n)
    lo == hi && return ""
    return String(codeunits(s)[(lo + 1):hi])
end

byte_slice(text::AbstractString, idx::AppBskyRichtextFacetByteSlice) =
    byte_slice(text, idx.byteStart, idx.byteEnd)

# -----------------------------------------------------------------------------
# Builder API (exact 0-based UTF-8 byte offsets)
# -----------------------------------------------------------------------------

"""
    RichTextBuilder()

Mutable builder for assembling a [`RichTextDoc`](@ref) with exact 0-based UTF-8
byte-offset facets.
"""
mutable struct RichTextBuilder
    io::IOBuffer
    facets::Vector{AppBskyRichtextFacet}
end

RichTextBuilder() = RichTextBuilder(IOBuffer(), AppBskyRichtextFacet[])

"""
    add_text!(b::RichTextBuilder, s::AbstractString) -> RichTextBuilder

Append plain text `s` to `b`.
"""
function add_text!(b::RichTextBuilder, s::AbstractString)
    write(b.io, String(s))
    return b
end

"""
    add_link!(b::RichTextBuilder, label::AbstractString, uri::AbstractString) -> RichTextBuilder

Append `label` annotated with an `app.bsky.richtext.facet#link` pointing to `uri`.
"""
function add_link!(b::RichTextBuilder, label::AbstractString, uri::AbstractString)
    s = String(label)
    start_b = b.io.size
    write(b.io, s)
    end_b = b.io.size
    push!(
        b.facets,
        AppBskyRichtextFacet(
            index = AppBskyRichtextFacetByteSlice(byteStart = start_b, byteEnd = end_b),
            features = LexiconObject[AppBskyRichtextFacetLink(uri = String(uri))],
        ),
    )
    return b
end

"""
    add_mention!(b::RichTextBuilder, label::AbstractString, did::Union{DID, AbstractString}) -> RichTextBuilder

Append `label` (typically `"@handle"`) annotated with an `app.bsky.richtext.facet#mention`
pointing to `did`.
"""
function add_mention!(b::RichTextBuilder, label::AbstractString, did::Union{DID, AbstractString})
    s = String(label)
    d = convert(DID, did)
    start_b = b.io.size
    write(b.io, s)
    end_b = b.io.size
    push!(
        b.facets,
        AppBskyRichtextFacet(
            index = AppBskyRichtextFacetByteSlice(byteStart = start_b, byteEnd = end_b),
            features = LexiconObject[AppBskyRichtextFacetMention(did = d)],
        ),
    )
    return b
end

"""
    add_tag!(b::RichTextBuilder, label::AbstractString; tag=nothing) -> RichTextBuilder

Append `label` (e.g. `"#julialang"`) annotated with an `app.bsky.richtext.facet#tag`.
If `tag` is omitted, any leading `'#'` or `'＃'` is stripped automatically for the
facet payload while remaining in the display text.
"""
function add_tag!(
    b::RichTextBuilder,
    label::AbstractString;
    tag::Union{AbstractString, Nothing} = nothing,
)
    s::String = String(label)
    tag_val = if isnothing(tag)
        if startswith(s, '#')
            s[nextind(s, 1):end]
        elseif startswith(s, '＃')
            s[nextind(s, 1):end]
        else
            s
        end
    else
        String(tag)
    end
    start_b = b.io.size
    write(b.io, s)
    end_b = b.io.size
    push!(
        b.facets,
        AppBskyRichtextFacet(
            index = AppBskyRichtextFacetByteSlice(byteStart = start_b, byteEnd = end_b),
            features = LexiconObject[AppBskyRichtextFacetTag(tag = tag_val)],
        ),
    )
    return b
end

"""
    build(b::RichTextBuilder) -> RichTextDoc

Finalize `b` into an immutable [`RichTextDoc`](@ref).
"""
function build(b::RichTextBuilder)
    txt = String(take!(copy(b.io)))
    return RichTextDoc(txt, copy(b.facets))
end

function RichTextDoc(f::Function)
    b = RichTextBuilder()
    f(b)
    return build(b)
end

# -----------------------------------------------------------------------------
# Segment iteration for rendering (HTML, Markdown, ANSI, etc.)
# -----------------------------------------------------------------------------

"""
    RichTextSegment

Contiguous slice of a [`RichTextDoc`](@ref) paired with its optional facet.
"""
struct RichTextSegment
    text::String
    facet::Union{AppBskyRichtextFacet, Nothing}
end

function _find_feature(seg::RichTextSegment, ::Type{T})::Union{T, Nothing} where {T}
    f = seg.facet
    isnothing(f) && return nothing
    for feat in f.features
        feat isa T && return feat::T
    end
    return nothing
end

is_mention(seg::RichTextSegment) = !isnothing(_find_feature(seg, AppBskyRichtextFacetMention))
is_link(seg::RichTextSegment) = !isnothing(_find_feature(seg, AppBskyRichtextFacetLink))
is_tag(seg::RichTextSegment) = !isnothing(_find_feature(seg, AppBskyRichtextFacetTag))

function mention_did(seg::RichTextSegment)
    m = _find_feature(seg, AppBskyRichtextFacetMention)
    return isnothing(m) ? nothing : m.did
end

function link_uri(seg::RichTextSegment)
    l = _find_feature(seg, AppBskyRichtextFacetLink)
    return isnothing(l) ? nothing : l.uri
end

function tag_value(seg::RichTextSegment)
    t = _find_feature(seg, AppBskyRichtextFacetTag)
    return isnothing(t) ? nothing : t.tag
end

"""
    segments(rt::RichTextDoc) -> Vector{RichTextSegment}

Split `rt` into ordered, non-overlapping plain and annotated [`RichTextSegment`](@ref)s.
"""
function segments(rt::RichTextDoc)
    segs = RichTextSegment[]
    n = ncodeunits(rt.text)
    isempty(rt.facets) && return n == 0 ? segs : [RichTextSegment(rt.text, nothing)]

    cursor = 0
    for facet in rt.facets
        bs = clamp(facet.index.byteStart, 0, n)
        be = clamp(facet.index.byteEnd, bs, n)
        # Skip invalid or overlapping spans that start before our current cursor
        (bs < cursor || be <= bs) && continue
        if bs > cursor
            push!(segs, RichTextSegment(byte_slice(rt.text, cursor, bs), nothing))
        end
        push!(segs, RichTextSegment(byte_slice(rt.text, bs, be), facet))
        cursor = be
    end
    if cursor < n
        push!(segs, RichTextSegment(byte_slice(rt.text, cursor, n), nothing))
    end
    return segs
end

# -----------------------------------------------------------------------------
# Automatic Facet Detection (mentions, links, hashtags)
# -----------------------------------------------------------------------------

const _MENTION_RX = r"(?:^|\s|\(|\[|\"|')(@([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)"

const _URL_RX = r"(?:^|\s|\(|\[)(?<url>(?:https?://)?(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}(?::[0-9]{1,5})?(?:/[^\s<>\"']*)?(?:\?[^\s<>\"']*)?(?:#[^\s<>\"']*)?)"

const _TAG_RX = r"(?:^|\s)(?<tag>[#＃][^\s#＃]+)"

const _TRAILING_URL_PUNCT = ('.', ',', ';', ':', '!', '?', '\'', '"', ']', '}')

function _trim_url(raw::AbstractString)
    s = String(raw)
    while !isempty(s)
        c = last(s)
        if c in _TRAILING_URL_PUNCT
            s = s[1:prevind(s, lastindex(s))]
        elseif c == ')' && count(==(')'), s) > count(==('('), s)
            # Strip unbalanced trailing ')' while preserving Wikipedia-style balanced parens
            s = s[1:prevind(s, lastindex(s))]
        else
            break
        end
    end
    return s
end

function _is_trailing_tag_punct(c::Char)
    return ispunct(c) || c in ('"', '\'', '”', '’', '»', '」', '』', '）', '】', '。', '、', '！', '？')
end

function _trim_tag(raw::AbstractString)
    s = String(raw)
    while !isempty(s)
        c = last(s)
        if _is_trailing_tag_punct(c)
            s = s[1:prevind(s, lastindex(s))]
        else
            break
        end
    end
    return s
end

function _overlaps_any(bs::Int, be::Int, spans::Vector{Tuple{Int, Int}})
    for (s, e) in spans
        (bs < e && s < be) && return true
    end
    return false
end

"""
    detect_mentions(text::AbstractString) -> Vector{NamedTuple{(:byteStart, :byteEnd, :handle), Tuple{Int, Int, Handle}}}

Detect `@handle` mentions in `text` and return their 0-based UTF-8 byte ranges
and validated [`Handle`](@ref)s. Does not match email addresses like `user@example.com`.
"""
function detect_mentions(text::AbstractString)
    s = String(text)
    results = NamedTuple{(:byteStart, :byteEnd, :handle), Tuple{Int, Int, Handle}}[]
    for m in eachmatch(_MENTION_RX, s)
        # Group 1 is `@handle`
        cap = m.captures[1]
        isnothing(cap) && continue
        cap_offset = m.offsets[1] # 1-based byte offset of '@'
        handle_str = SubString(cap, 2)
        is_valid_handle(handle_str) || continue
        bs = cap_offset - 1
        be = bs + ncodeunits(cap)
        push!(results, (byteStart = bs, byteEnd = be, handle = Handle(handle_str)))
    end
    return results
end

function _extract_url_host(url::AbstractString)
    s = startswith(url, "https://") ? SubString(url, 9) :
        startswith(url, "http://") ? SubString(url, 8) : SubString(url, 1)
    # Stop at '/', '?', '#', or ':' (port)
    stop_idx = findfirst(c -> c == '/' || c == '?' || c == '#' || c == ':', s)
    return isnothing(stop_idx) ? s : SubString(s, 1, prevind(s, stop_idx))
end

"""
    detect_links(text::AbstractString) -> Vector{NamedTuple{(:byteStart, :byteEnd, :uri), Tuple{Int, Int, String}}}

Detect HTTP(S) and bare-domain URLs in `text`, stripping trailing punctuation and
unbalanced closing parentheses, and returning 0-based UTF-8 byte ranges and
normalized URIs (`"https://"` prepended for bare domains).
"""
function detect_links(text::AbstractString)
    s = String(text)
    results = NamedTuple{(:byteStart, :byteEnd, :uri), Tuple{Int, Int, String}}[]
    for m in eachmatch(_URL_RX, s)
        raw_url = m[:url]
        isnothing(raw_url) && continue
        trimmed = _trim_url(raw_url)
        isempty(trimmed) && continue

        has_scheme = startswith(trimmed, "http://") || startswith(trimmed, "https://")
        host = _extract_url_host(trimmed)
        is_valid_handle(host) || continue
        if !has_scheme
            # Bare domains must use a valid non-reserved TLD
            is_valid_tld(host) || continue
        end

        uri = has_scheme ? trimmed : "https://" * trimmed
        # Locate exact 1-based byte offset of the named :url capture
        url_offset = m.offsets[1]
        bs = url_offset - 1
        be = bs + ncodeunits(trimmed)
        push!(results, (byteStart = bs, byteEnd = be, uri = uri))
    end
    return results
end

"""
    detect_tags(text::AbstractString) -> Vector{NamedTuple{(:byteStart, :byteEnd, :tag), Tuple{Int, Int, String}}}

Detect Bluesky hashtags (`#tag` / `＃tag`) in `text`, excluding purely numeric
tags (e.g. `#123`), stripping trailing punctuation, and enforcing the 64-grapheme
and 640-byte Bluesky tag limits.
"""
function detect_tags(text::AbstractString)
    s = String(text)
    results = NamedTuple{(:byteStart, :byteEnd, :tag), Tuple{Int, Int, String}}[]
    for m in eachmatch(_TAG_RX, s)
        raw_tag = m[:tag]
        isnothing(raw_tag) && continue
        trimmed = _trim_tag(raw_tag)
        isempty(trimmed) && continue
        # Must still have a prefix ('#' or '＃') plus non-empty body
        body_start = nextind(trimmed, 1)
        body_start > lastindex(trimmed) && continue
        tag_body = trimmed[body_start:end]
        isempty(tag_body) && continue
        # Reject purely numeric tags like `#123`
        all(isdigit, tag_body) && continue
        # Enforce ATProto lexicon limits on hashtag payload
        (ncodeunits(tag_body) <= 640 && length(Unicode.graphemes(tag_body)) <= 64) || continue

        tag_offset = m.offsets[1]
        bs = tag_offset - 1
        be = bs + ncodeunits(trimmed)
        push!(results, (byteStart = bs, byteEnd = be, tag = tag_body))
    end
    return results
end

function _resolve_via_dict(tbl::AbstractDict, h::Handle)
    v = get(tbl, h, nothing)
    isnothing(v) && (v = get(tbl, String(h), nothing))
    isnothing(v) && return nothing
    return v isa DID ? v : tryparse(DID, string(v))
end

"""
    detect_facets(text::AbstractString; resolve_handle=nothing) -> Vector{AppBskyRichtextFacet}
    detect_facets(agent::AtpAgent, text::AbstractString) -> Vector{AppBskyRichtextFacet}

Detect links, hashtags, and (when `resolve_handle` or an `AtpAgent` is provided)
mentions in `text`, returning sorted, non-overlapping `AppBskyRichtextFacet`s
with 0-based UTF-8 byte offsets.

`resolve_handle` may be:
- `nothing` (detects links and hashtags offline; skips mentions)
- a callable `(h::Handle) -> Union{DID, AbstractString, Nothing}`
- an `AbstractDict` mapping `Handle` or `String` handles to `DID`s
"""
function detect_facets(text::AbstractString; resolve_handle = nothing)
    s = String(text)
    facets = AppBskyRichtextFacet[]
    occupied = Tuple{Int, Int}[]

    # 1. Links first (prevents URL `#fragment`s or `@user` paths from being misclassified)
    for lnk in detect_links(s)
        push!(occupied, (lnk.byteStart, lnk.byteEnd))
        push!(
            facets,
            AppBskyRichtextFacet(
                index = AppBskyRichtextFacetByteSlice(byteStart = lnk.byteStart, byteEnd = lnk.byteEnd),
                features = LexiconObject[AppBskyRichtextFacetLink(uri = lnk.uri)],
            ),
        )
    end

    # 2. Mentions (resolved via callback or lookup dict, deduplicated per call)
    if !isnothing(resolve_handle)
        cache = Dict{Handle, Union{DID, Nothing}}()
        for men in detect_mentions(s)
            _overlaps_any(men.byteStart, men.byteEnd, occupied) && continue
            did = get!(cache, men.handle) do
                res = resolve_handle isa AbstractDict ?
                    _resolve_via_dict(resolve_handle, men.handle) :
                    resolve_handle(men.handle)
                isnothing(res) ? nothing : (res isa DID ? res : tryparse(DID, string(res)))
            end
            isnothing(did) && continue
            push!(occupied, (men.byteStart, men.byteEnd))
            push!(
                facets,
                AppBskyRichtextFacet(
                    index = AppBskyRichtextFacetByteSlice(byteStart = men.byteStart, byteEnd = men.byteEnd),
                    features = LexiconObject[AppBskyRichtextFacetMention(did = did)],
                ),
            )
        end
    end

    # 3. Hashtags (skipping any overlap with URLs or mentions)
    for tg in detect_tags(s)
        _overlaps_any(tg.byteStart, tg.byteEnd, occupied) && continue
        push!(occupied, (tg.byteStart, tg.byteEnd))
        push!(
            facets,
            AppBskyRichtextFacet(
                index = AppBskyRichtextFacetByteSlice(byteStart = tg.byteStart, byteEnd = tg.byteEnd),
                features = LexiconObject[AppBskyRichtextFacetTag(tag = tg.tag)],
            ),
        )
    end

    sort!(facets; by = f -> (f.index.byteStart, f.index.byteEnd))
    return facets
end

function detect_facets(agent::AtpAgent, text::AbstractString)
    resolver = function (h::Handle)
        try
            out = xrpc(agent, "com.atproto.identity.resolveHandle"; handle = h)
            return out.did
        catch e
            e isa XRPCError && return nothing
            rethrow()
        end
    end
    return detect_facets(text; resolve_handle = resolver)
end

"""
    richtext(text::AbstractString; resolve_handle=nothing) -> RichTextDoc
    richtext(agent::AtpAgent, text::AbstractString) -> RichTextDoc

Detect facets in `text` and return a [`RichTextDoc`](@ref).
"""
richtext(text::AbstractString; resolve_handle = nothing) =
    RichTextDoc(String(text), detect_facets(text; resolve_handle = resolve_handle))

richtext(agent::AtpAgent, text::AbstractString) =
    RichTextDoc(String(text), detect_facets(agent, text))

end # module RichText
