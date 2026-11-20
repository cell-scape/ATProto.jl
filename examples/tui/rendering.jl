# Retro-future CRT tube monitor & vintage PC chassis rendering helpers for BlueskyTUI.
# Converts ATProto.jl Lexicon structs and RichText documents into layered Tachikoma surfaces:
# boxy CRT bezels, cooling vents, floppy drive bays, phosphor glass scanlines, rotary knobs,
# multi-line post cards, tactile keycap chips, and theme-adaptive Spans.

const _ISO_FORMATS = (
    dateformat"yyyy-mm-ddTHH:MM:SS.sss",
    dateformat"yyyy-mm-ddTHH:MM:SS",
)

# ── Time & Number Formatting ────────────────────────────────────────

function parse_iso_utc(s::AbstractString)::Union{DateTime, Nothing}
    cleaned = strip(String(s))
    isempty(cleaned) && return nothing
    m = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?", cleaned)
    isnothing(m) && return nothing
    base = m.captures[1]
    frac = m.captures[2]
    if !isnothing(frac)
        ms = rpad(first(frac, 3), 3, '0')
        try
            return DateTime("$(base).$(ms)", _ISO_FORMATS[1])
        catch
        end
    end
    try
        return DateTime(base, _ISO_FORMATS[2])
    catch
        return nothing
    end
end

function format_relative_time(iso::Union{AbstractString, Nothing}; ref::DateTime = now(UTC))::String
    isnothing(iso) && return ""
    dt = parse_iso_utc(iso)
    isnothing(dt) && return first(String(iso), 10)
    delta_s = Dates.value(ref - dt) ÷ 1000
    if delta_s < 0
        return "now"
    elseif delta_s < 60
        return "$(delta_s)s"
    elseif delta_s < 3600
        return "$(delta_s ÷ 60)m"
    elseif delta_s < 86400
        return "$(delta_s ÷ 3600)h"
    elseif delta_s < 86400 * 30
        return "$(delta_s ÷ 86400)d"
    else
        return Dates.format(dt, dateformat"yyyy-mm-dd")
    end
end

function format_count(n::Union{Integer, Nothing})::String
    v = something(n, 0)
    v < 1_000 && return string(v)
    v < 1_000_000 && return @sprintf("%.1fK", v / 1_000)
    return @sprintf("%.1fM", v / 1_000_000)
end

function bsky_post_url(post::API.AppBskyFeedDefsPostView)::String
    rk = ATProto.Syntax.rkey(post.uri)
    isnothing(rk) && return "https://bsky.app/profile/$(post.author.handle)"
    return "https://bsky.app/profile/$(post.author.handle)/post/$(rk)"
end

bsky_profile_url(actor) = "https://bsky.app/profile/$(actor)"

function safe_one_line(s::AbstractString)::String
    replace(strip(String(s)), r"[\r\n\t]+" => " ")
end

function truncate_chars(s::AbstractString, max_cols::Int)::String
    max_cols <= 0 && return ""
    textwidth(s) <= max_cols && return String(s)
    budget = max(0, max_cols - 1)
    io = IOBuffer()
    acc = 0
    for g in Base.Unicode.graphemes(s)
        gw = textwidth(g)
        acc + gw > budget && break
        print(io, g)
        acc += gw
    end
    return String(take!(io)) * "…"
end

function _monogram(name::AbstractString, handle::AbstractString)::String
    src = isempty(strip(name)) ? String(handle) : strip(String(name))
    for ch in src
        if isletter(ch) || isdigit(ch)
            return uppercase(string(ch))
        end
    end
    return "◈"
end

# ── Vintage Hardware Surface Palette (Chassis / CRT Glass / Pills) ──

_canvas_bg_rgb()::ColorRGB = to_rgb(theme().bg)

"""Outer vintage polycarbonate / metal monitor chassis casing tone."""
function _chassis_bg()::ColorRGB
    base = to_rgb(theme().bg)
    return light_mode() ? dim_color(base, 0.08) : brighten(base, 0.075)
end

"""Recessed dark phosphor CRT tube glass interior."""
function _crt_glass_bg()::ColorRGB
    base = to_rgb(theme().bg)
    return light_mode() ? dim_color(base, 0.015) : dim_color(base, 0.34)
end

"""Subtle alternating CRT raster scanline row shade."""
function _crt_scanline_bg()::ColorRGB
    g = _crt_glass_bg()
    return light_mode() ? dim_color(g, 0.03) : brighten(g, 0.025)
end

"""Elevated matte deck surface (bars, footers)."""
function _surface_bg()::ColorRGB
    base = to_rgb(theme().bg)
    return light_mode() ? dim_color(base, 0.04) : brighten(base, 0.04)
end

"""Floating vintage dialog background."""
function _modal_bg()::ColorRGB
    base = _chassis_bg()
    return light_mode() ? brighten(base, 0.03) : brighten(base, 0.02)
end

"""Selected post card phosphor highlight wash inside the CRT glass."""
function _card_selected_bg()::ColorRGB
    base = _crt_glass_bg()
    accent = to_rgb(theme().primary)
    return color_lerp(base, accent, light_mode() ? 0.16 : 0.22)
end

function _pill_bg(field::Symbol = :primary)::ColorRGB
    base = _crt_glass_bg()
    c = to_rgb(getfield(theme(), field))
    return color_lerp(base, c, light_mode() ? 0.20 : 0.26)
end

function _chip_style(field::Symbol; bold::Bool = true, hyperlink::String = "")::Style
    return Style(fg = getfield(theme(), field), bg = _pill_bg(field), bold = bold, hyperlink = hyperlink)
end

function _inverted_pill_style(field::Symbol)::Style
    fg = light_mode() ? ColorRGB(255, 255, 255) : ColorRGB(12, 14, 18)
    return Style(fg = fg, bg = to_rgb(getfield(theme(), field)), bold = true)
end

function _keycap_style()::Style
    bg = color_lerp(_surface_bg(), to_rgb(theme().accent), light_mode() ? 0.24 : 0.30)
    fg = to_rgb(theme().text_bright)
    return Style(fg = fg, bg = bg, bold = true)
end

function _fill_surface!(buf::Buffer, rect::Rect, bg::AbstractColor)
    s = Style(bg = bg)
    for row in rect.y:min(bottom(rect), bottom(buf.area))
        for col in rect.x:min(right(rect), right(buf.area))
            set_char!(buf, col, row, ' ', s)
        end
    end
end

"""Fill a CRT glass viewport with recessed phosphor glass + optional subtle raster scanlines."""
function _fill_crt_glass!(buf::Buffer, rect::Rect; scanlines::Bool = true)
    g1 = _crt_glass_bg()
    g2 = scanlines ? _crt_scanline_bg() : g1
    for row in rect.y:min(bottom(rect), bottom(buf.area))
        s = Style(bg = (row % 2 == 0) ? g1 : g2)
        for col in rect.x:min(right(rect), right(buf.area))
            set_char!(buf, col, row, ' ', s)
        end
    end
end

function _draw_shadow!(buf::Buffer, rect::Rect, bounds::Rect)
    shadow_bg = light_mode() ? dim_color(to_rgb(theme().bg), 0.20) : dim_color(to_rgb(theme().bg), 0.72)
    shadow_s = Style(fg = shadow_bg, bg = shadow_bg)
    sy = bottom(rect) + 1
    if sy <= bottom(bounds)
        for sx in (rect.x + 2):min(right(rect) + 2, right(bounds))
            set_char!(buf, sx, sy, ' ', shadow_s)
        end
    end
    for sy2 in (rect.y + 1):min(bottom(rect) + 1, bottom(bounds))
        for dx in 1:2
            sx = right(rect) + dx
            sx <= right(bounds) && set_char!(buf, sx, sy2, ' ', shadow_s)
        end
    end
end

function _led_rgb(field::Symbol, tick::Int; active::Bool = true)::ColorRGB
    c = to_rgb(getfield(theme(), field))
    active || return dim_color(c, 0.55)
    if animations_enabled()
        b = breathe(tick; period = 95)
        return brighten(c, b * 0.35)
    end
    return c
end

# ── Boxy CRT Tube Monitor & Ancient PC Chassis Renderer ─────────────

"""
    render_crt_monitor!(buf, rect; kwargs...) -> Rect

Render a boxy retro CRT tube monitor or vintage desktop PC enclosure:
- Thick outer casing (`BOX_HEAVY` / `BOX_DOUBLE`) with plastic bezel tone & top cooling vents (`≡≡≡`)
- Recessed curved glass CRT tube (`BOX_ROUNDED`) with deep phosphor glass + optional raster scanlines
- Bottom monitor chin with hardware controls (rotary knobs `◉ BRT  ◉ CNT`, floppy drive slot `[ ▬▬▬▬●▬▬▬▬ ]`,
  terminal status lamps, speaker grille `⋮⋮⋮⋮⋮`, and a breathing `● PWR` LED)
- Optional boxy swivel desk pedestal (`pedestal=true`) on full-screen monitor tabs

Returns the padded interior `Rect` of the glowing CRT glass screen.
"""
function render_crt_monitor!(
    buf::Buffer,
    rect::Rect;
    model_tag::AbstractString = "PVM-14",
    title::AbstractString = "",
    title_right::AbstractString = "",
    title_right_style::Union{Style, Nothing} = nothing,
    chin_left::Vector{Span} = Span[],
    pwr_label::AbstractString = "PWR",
    pwr_field::Symbol = :success,
    pwr_active::Bool = true,
    focused::Bool = false,
    tick::Int = 0,
    scanlines::Bool = true,
    pedestal::Bool = false,
    accent_field::Symbol = :border_focus,
    outer_box::NamedTuple = BOX_HEAVY,
)::Rect
    (rect.width < 12 || rect.height < 6) && return inner(rect)

    # Reserve 2 rows at bottom for vintage CRT swivel pedestal when requested and tall enough
    draw_ped = pedestal && rect.height >= 16 && rect.width >= 36
    mon_rect = draw_ped ? Rect(rect.x, rect.y, rect.width, rect.height - 2) : rect

    cbg = _chassis_bg()
    _fill_surface!(buf, mon_rect, cbg)

    # Outer boxy monitor shell
    shell_color = focused ? getfield(theme(), accent_field) : theme().border
    if focused
        border_shimmer!(buf, mon_rect, shell_color, tick; box = outer_box, intensity = 0.20)
    else
        render(Block(border_style = Style(fg = shell_color, bg = cbg), box = outer_box), mon_rect, buf)
    end

    # Top chassis hood: cooling louvers ≡≡≡ + vintage model nameplate + title + right badge
    vent_s = Style(fg = theme().text_dim, bg = cbg, dim = true)
    cx = mon_rect.x + 2
    if mon_rect.width >= 42
        cx = set_string!(buf, cx, mon_rect.y, "≡≡≡ ", vent_s; max_x = right(mon_rect) - 4)
    end
    if !isempty(model_tag) && mon_rect.width >= 28
        cx = set_string!(buf, cx, mon_rect.y, " $model_tag ", _inverted_pill_style(focused ? accent_field : :secondary); max_x = right(mon_rect) - 4)
        cx = set_string!(buf, cx, mon_rect.y, " ", Style(bg = cbg); max_x = right(mon_rect) - 4)
    end
    if !isempty(title) && cx < right(mon_rect) - 8
        t_sty = focused ? _chip_style(:accent; bold = true) : Style(fg = theme().title, bg = cbg, bold = true)
        max_tw = max(4, right(mon_rect) - cx - 10)
        lbl = " $(truncate_chars(title, max_tw)) "
        cx = set_string!(buf, cx, mon_rect.y, lbl, t_sty; max_x = right(mon_rect) - 6)
    end

    # Right hood louvers + optional right status pill
    rx_end = right(mon_rect) - 1
    if mon_rect.width >= 42
        set_string!(buf, rx_end - 3, mon_rect.y, " ≡≡≡", vent_s; max_x = rx_end)
        rx_end -= 5
    end
    if !isempty(title_right) && rx_end > cx + 4
        r_sty = something(title_right_style, Style(fg = theme().text_dim, bg = cbg))
        padded = " $(title_right) "
        tx = rx_end - textwidth(padded) + 1
        if tx > cx + 1
            set_string!(buf, tx, mon_rect.y, padded, r_sty; max_x = rx_end)
        end
    end

    # Recessed curved CRT glass screen nested inside the outer boxy chassis!
    use_nested_bezel = (mon_rect.width >= 26 && mon_rect.height >= 9)
    screen_content = if use_nested_bezel
        tube_rect = Rect(mon_rect.x + 2, mon_rect.y + 1, mon_rect.width - 4, mon_rect.height - 2)
        _fill_crt_glass!(buf, tube_rect; scanlines = scanlines)
        rim_fg = focused ? color_lerp(to_rgb(theme().border), to_rgb(getfield(theme(), accent_field)), 0.45) : to_rgb(theme().border)
        rim_s = Style(fg = rim_fg, bg = _crt_glass_bg())
        render(Block(border_style = rim_s, box = BOX_ROUNDED), tube_rect, buf)
        inn = inner(tube_rect)
        inn.width > 6 ? margin(inn; left = 1, right = 1) : inn
    else
        inn = inner(mon_rect)
        _fill_crt_glass!(buf, inn; scanlines = scanlines)
        inn.width > 4 ? margin(inn; left = 1, right = 1) : inn
    end

    # Bottom monitor chin: left hardware controls (knobs / floppy bay / lamps) + right grille & breathing PWR LED
    chin_y = bottom(mon_rect)
    cx_chin = mon_rect.x + 2
    if isempty(chin_left)
        knob_s = Style(fg = theme().text_dim, bg = cbg)
        cx_chin = set_string!(buf, cx_chin, chin_y, " ◉ BRT  ◉ CNT ", knob_s; max_x = right(mon_rect) - 18)
    else
        for sp in chin_left
            cx_chin > right(mon_rect) - 16 && break
            sty = sp.style.bg isa NoColor ? Style(fg = sp.style.fg, bg = cbg, bold = sp.style.bold, dim = sp.style.dim) : sp.style
            cx_chin = set_string!(buf, cx_chin, chin_y, sp.content, sty; max_x = right(mon_rect) - 16)
        end
    end

    # Right chin: speaker grille ⋮⋮⋮⋮⋮ + glowing power LED
    pwr_str = " ● $pwr_label "
    grille = mon_rect.width >= 44 ? "⋮⋮⋮⋮⋮  " : ""
    total_rw = textwidth(grille) + textwidth(pwr_str)
    rx_chin = right(mon_rect) - 1 - total_rw
    if rx_chin > cx_chin + 1
        if !isempty(grille)
            rx_chin = set_string!(buf, rx_chin, chin_y, grille, Style(fg = theme().text_dim, bg = cbg, dim = true); max_x = right(mon_rect) - 2)
        end
        led_c = _led_rgb(pwr_field, tick; active = pwr_active)
        set_string!(buf, rx_chin, chin_y, "●", Style(fg = led_c, bg = cbg, bold = true); max_x = right(mon_rect) - 2)
        set_string!(buf, rx_chin + 1, chin_y, " $pwr_label ", Style(fg = theme().text_dim, bg = cbg, bold = pwr_active); max_x = right(mon_rect) - 2)
    end

    # Boxy CRT swivel neck & desk pedestal underneath full-screen monitors!
    if draw_ped
        ped_c = focused ? getfield(theme(), accent_field) : theme().border
        ped_s = Style(fg = ped_c, bg = _canvas_bg_rgb())
        ped_dim = Style(fg = theme().border, bg = _canvas_bg_rgb(), dim = true)
        neck = "╰═══╦═══╯"
        base = "╭───────╨───────╮"
        nx = mon_rect.x + max(0, (mon_rect.width - textwidth(neck)) ÷ 2)
        bx = mon_rect.x + max(0, (mon_rect.width - textwidth(base)) ÷ 2)
        set_string!(buf, nx, bottom(mon_rect) + 1, neck, ped_s; max_x = right(mon_rect))
        set_string!(buf, bx, bottom(mon_rect) + 2, base, ped_dim; max_x = right(mon_rect))
    end

    return screen_content
end

"""
    render_floating_modal!(buf, area, w, h; title, title_right, tick) -> Rect

Draw a centered floating vintage Borland/OS/2-style double-bordered CRT dialog
with heavy drop shadow, elevated chassis fill, and living border shimmer.
"""
function render_floating_modal!(
    buf::Buffer,
    area::Rect,
    w::Int,
    h::Int;
    title::AbstractString = "",
    title_right::AbstractString = "",
    tick::Int = 0,
)::Rect
    box_r = center(area, min(w, max(16, area.width - 4)), min(h, max(6, area.height - 2)))
    _draw_shadow!(buf, box_r, area)
    mbg = _modal_bg()
    _fill_surface!(buf, box_r, mbg)
    border_shimmer!(buf, box_r, theme().accent, tick; box = BOX_DOUBLE, intensity = 0.22)

    if !isempty(title) && box_r.width > 10
        lbl = " ◈ $(truncate_chars(title, max(4, box_r.width - 14))) "
        set_string!(buf, box_r.x + 2, box_r.y, lbl, _inverted_pill_style(:accent); max_x = right(box_r) - 6)
    end
    if !isempty(title_right) && box_r.width > 18
        padded = " $(title_right) "
        tx = right(box_r) - 5 - textwidth(padded)
        if tx > box_r.x + textwidth(title) + 8
            set_string!(buf, tx, box_r.y, padded, Style(fg = theme().text_dim, bg = mbg); max_x = right(box_r) - 5)
        end
    end
    # Classic vintage window close box [×]
    if box_r.width > 12
        set_string!(buf, right(box_r) - 4, box_r.y, "[×]", Style(fg = theme().text_dim, bg = mbg); max_x = right(box_r) - 1)
    end

    inn = inner(box_r)
    return inn.width > 4 ? margin(inn; left = 1, right = 1) : inn
end

"""
    render_keycap_bar!(buf, x, y, pairs; max_x, bg) -> Int

Render chunky vintage mechanical-keyboard keycap chips (`[key]` label).
"""
function render_keycap_bar!(
    buf::Buffer,
    x::Int,
    y::Int,
    pairs::AbstractVector{<:Tuple{AbstractString, AbstractString}};
    max_x::Int = right(buf.area),
    bg::AbstractColor = _surface_bg(),
)::Int
    cx = x
    k_sty = _keycap_style()
    l_sty = Style(fg = theme().text_dim, bg = bg)
    for (k, desc) in pairs
        need = textwidth(k) + textwidth(desc) + 5
        cx + need - 1 > max_x && break
        cx = set_string!(buf, cx, y, " $k ", k_sty; max_x = max_x)
        cx = set_string!(buf, cx, y, " $desc  ", l_sty; max_x = max_x)
    end
    return cx
end

# ── Unified Feed Entry ──────────────────────────────────────────────

struct FeedEntry
    post::API.AppBskyFeedDefsPostView
    reposted_by::Union{String, Nothing}
    is_pinned::Bool
    reply_parent_handle::Union{String, Nothing}
end

function FeedEntry(item::API.AppBskyFeedDefsFeedViewPost)
    reposted_by = if item.reason isa API.AppBskyFeedDefsReasonRepost
        String(item.reason.by.handle)
    else
        nothing
    end
    is_pinned = item.reason isa API.AppBskyFeedDefsReasonPin
    parent_handle = if !isnothing(item.reply) && item.reply.parent isa API.AppBskyFeedDefsPostView
        String(item.reply.parent.author.handle)
    else
        nothing
    end
    return FeedEntry(item.post, reposted_by, is_pinned, parent_handle)
end

FeedEntry(post::API.AppBskyFeedDefsPostView) = FeedEntry(post, nothing, false, nothing)

# ── RichText → Vector{Vector{Span}} ─────────────────────────────────

function segment_style(seg::RichTextSegment)::Style
    if is_mention(seg)
        did = mention_did(seg)
        url = isnothing(did) ? "" : bsky_profile_url(did)
        return tstyle(:accent, bold = true, hyperlink = url)
    elseif is_link(seg)
        uri = something(link_uri(seg), "")
        return tstyle(:primary, underline = true, hyperlink = uri)
    elseif is_tag(seg)
        tag = something(tag_value(seg), "")
        url = isempty(tag) ? "" : "https://bsky.app/hashtag/$(tag)"
        return tstyle(:warning, bold = true, hyperlink = url)
    else
        return tstyle(:text)
    end
end

"""
    richtext_to_span_lines(text, facets; prefix_spans=Span[]) -> Vector{Vector{Span}}

Convert ATProto RichText text + facets into Tachikoma `Span` lines, preserving
explicit newlines and attaching clickable OSC-8 hyperlinks to links, mentions,
and hashtags.
"""
function richtext_to_span_lines(
    text::AbstractString,
    facets = nothing;
    prefix_spans::Vector{Span} = Span[],
)::Vector{Vector{Span}}
    segs = if isnothing(facets) || isempty(facets)
        [RichTextSegment(String(text), nothing)]
    else
        collect(segments(RichTextDoc(String(text), facets)))
    end

    lines = Vector{Vector{Span}}()
    cur = copy(prefix_spans)

    for seg in segs
        sty = segment_style(seg)
        parts = split(seg.text, '\n'; keepempty = true)
        for (pi, part) in enumerate(parts)
            if pi > 1
                push!(lines, cur)
                cur = copy(prefix_spans)
            end
            isempty(part) || push!(cur, Span(String(part), sty))
        end
    end
    push!(lines, cur)
    return lines
end

# ── Embed Badges & Framed Embed Cards ───────────────────────────────

function embed_badge(embed)::String
    isnothing(embed) && return ""
    if embed isa API.AppBskyEmbedImagesView
        n = length(embed.images)
        return n == 1 ? "▣ IMG" : "▣ $(n) IMG"
    elseif embed isa API.AppBskyEmbedVideoView
        return "▶ VID"
    elseif embed isa API.AppBskyEmbedExternalView
        return "◈ LINK"
    elseif embed isa API.AppBskyEmbedRecordView
        return "❝ QUOTE"
    elseif embed isa API.AppBskyEmbedRecordWithMediaView
        return "❝ MEDIA"
    elseif embed isa UnknownObject
        return "◇ EMBED"
    end
    return "◇ EMBED"
end

function _embed_badge_field(embed)::Symbol
    if embed isa API.AppBskyEmbedImagesView
        return :accent
    elseif embed isa API.AppBskyEmbedVideoView
        return :warning
    elseif embed isa API.AppBskyEmbedExternalView
        return :primary
    elseif embed isa API.AppBskyEmbedRecordView || embed isa API.AppBskyEmbedRecordWithMediaView
        return :success
    end
    return :secondary
end

function embed_to_span_lines(embed; indent::String = "")::Vector{Vector{Span}}
    isnothing(embed) && return Vector{Span}[]
    lines = Vector{Vector{Span}}()
    ind_span = isempty(indent) ? Span[] : [Span(indent, tstyle(:text_dim))]
    border_s = tstyle(:border)
    dim_s = tstyle(:text_dim)
    accent_s = tstyle(:accent)

    function push_card!(spans::Vector{Span})
        push!(lines, vcat(ind_span, spans))
    end

    if embed isa API.AppBskyEmbedImagesView
        n = length(embed.images)
        push_card!([Span("╭─ ", border_s), Span(" ▣ Images ($n) ", _chip_style(:accent))])
        for (i, img) in enumerate(embed.images)
            dims = if !isnothing(img.aspectRatio)
                " $(img.aspectRatio.width)×$(img.aspectRatio.height)"
            else
                ""
            end
            alt = isempty(strip(img.alt)) ? "(no alt text)" : safe_one_line(img.alt)
            push_card!([
                Span("│ ", border_s),
                Span("[$i$dims] ", accent_s),
                Span("open ↗", tstyle(:primary, underline = true, hyperlink = img.fullsize)),
                Span("  ·  ", dim_s),
                Span(alt, tstyle(:text)),
            ])
        end
        push_card!([Span("╰" * "╌"^40, border_s)])

    elseif embed isa API.AppBskyEmbedVideoView
        dims = if !isnothing(embed.aspectRatio)
            " $(embed.aspectRatio.width)×$(embed.aspectRatio.height)"
        else
            ""
        end
        push_card!([Span("╭─ ", border_s), Span(" ▶ Video$dims ", _chip_style(:warning))])
        if !isnothing(embed.alt) && !isempty(strip(embed.alt))
            push_card!([Span("│ ", border_s), Span(safe_one_line(embed.alt), tstyle(:text))])
        end
        push_card!([
            Span("│ ", border_s),
            Span("Stream: ", dim_s),
            Span(embed.playlist, tstyle(:primary, underline = true, hyperlink = embed.playlist)),
        ])
        push_card!([Span("╰" * "╌"^40, border_s)])

    elseif embed isa API.AppBskyEmbedExternalView
        ext = embed.external
        push_card!([Span("╭─ ", border_s), Span(" ◈ Link Card ", _chip_style(:primary))])
        if !isempty(strip(ext.title))
            push_card!([
                Span("│ ", border_s),
                Span(safe_one_line(ext.title), tstyle(:text_bright, bold = true, hyperlink = ext.uri)),
            ])
        end
        if !isempty(strip(ext.description))
            push_card!([Span("│ ", border_s), Span(safe_one_line(ext.description), dim_s)])
        end
        push_card!([
            Span("│ ", border_s),
            Span(ext.uri, tstyle(:primary, underline = true, hyperlink = ext.uri)),
        ])
        push_card!([Span("╰" * "╌"^40, border_s)])

    elseif embed isa API.AppBskyEmbedRecordView
        append!(lines, _quoted_record_lines(embed.record; indent = indent))

    elseif embed isa API.AppBskyEmbedRecordWithMediaView
        append!(lines, embed_to_span_lines(embed.media; indent = indent))
        if !isnothing(embed.record)
            append!(lines, _quoted_record_lines(embed.record.record; indent = indent))
        end

    elseif embed isa UnknownObject
        t = something(lexicon_type(embed), "unknown")
        push_card!([Span("◇ [Embed: $t]", dim_s)])
    else
        push_card!([Span("◇ [Embed: $(typeof(embed))]", dim_s)])
    end

    return lines
end

function _quoted_record_lines(rec; indent::String = "")::Vector{Vector{Span}}
    lines = Vector{Vector{Span}}()
    ind_span = isempty(indent) ? Span[] : [Span(indent, tstyle(:text_dim))]
    border_s = tstyle(:border)
    dim_s = tstyle(:text_dim)

    if rec isa API.AppBskyEmbedRecordViewRecord
        author = rec.author
        name = something(author.displayName, "")
        hdr = isempty(name) ? "@$(author.handle)" : "$name · @$(author.handle)"
        rel = format_relative_time(rec.indexedAt)
        push!(lines, vcat(ind_span, [
            Span("╭─ ", border_s),
            Span(" ❝ Quote ", _chip_style(:success)),
            Span(" ", dim_s),
            Span(hdr, tstyle(:accent, bold = true, hyperlink = bsky_profile_url(author.handle))),
            Span(isempty(rel) ? "" : " · $rel", dim_s),
        ]))
        val = rec.value
        if val isa API.AppBskyFeedPost
            qprefix = vcat(ind_span, [Span("│ ", border_s)])
            append!(lines, richtext_to_span_lines(val.text, val.facets; prefix_spans = qprefix))
        else
            push!(lines, vcat(ind_span, [Span("│ ", border_s), Span("<record>", dim_s)]))
        end
        push!(lines, vcat(ind_span, [Span("╰" * "╌"^40, border_s)]))
    elseif rec isa API.AppBskyEmbedRecordViewNotFound
        push!(lines, vcat(ind_span, [Span("◌ [Quoted post not found]", dim_s)]))
    elseif rec isa API.AppBskyEmbedRecordViewBlocked
        push!(lines, vcat(ind_span, [Span("◌ [Quoted post blocked]", dim_s)]))
    elseif rec isa API.AppBskyEmbedRecordViewDetached
        push!(lines, vcat(ind_span, [Span("◌ [Quoted post detached]", dim_s)]))
    elseif rec isa API.AppBskyFeedDefsGeneratorView
        push!(lines, vcat(ind_span, [
            Span("╭─ ", border_s),
            Span(" ◈ Feed ", _chip_style(:primary)),
            Span(" $(rec.displayName)", tstyle(:title, bold = true)),
            Span(" by @$(rec.creator.handle)", dim_s),
        ]))
        push!(lines, vcat(ind_span, [Span("╰" * "╌"^40, border_s)]))
    elseif rec isa API.AppBskyGraphDefsListView
        push!(lines, vcat(ind_span, [
            Span("╭─ ", border_s),
            Span(" ▤ List ", _chip_style(:primary)),
            Span(" $(rec.name)", tstyle(:title, bold = true)),
            Span(" by @$(rec.creator.handle)", dim_s),
        ]))
        push!(lines, vcat(ind_span, [Span("╰" * "╌"^40, border_s)]))
    else
        t = something(lexicon_type(rec), string(typeof(rec)))
        push!(lines, vcat(ind_span, [Span("◇ [Quoted record: $t]", dim_s)]))
    end
    return lines
end

# ── Multi-Line Comfy Post Cards (Inside AT-5150 CRT Viewport) ───────

const FEED_CARD_STRIDE = 4  # 3 content rows + 1 retro scanline divider

function feed_card_hit_index(area::Rect, offset::Int, n_entries::Int, x::Int, y::Int)::Int
    (area.width < 1 || area.height < 1 || n_entries == 0) && return 0
    Base.contains(area, x, y) || return 0
    rel_y = y - area.y
    slot = rel_y ÷ FEED_CARD_STRIDE
    idx = offset + slot + 1
    return (1 <= idx <= n_entries) ? idx : 0
end

function render_feed_cards!(
    buf::Buffer,
    area::Rect,
    entries::Vector{FeedEntry},
    selected::Int,
    offset::Int;
    focused::Bool = true,
    tick::Int = 0,
    scanlines::Bool = true,
    bookmarked_uris::Set{String} = Set{String}(),
)::Int
    (area.width < 6 || area.height < 3) && return offset
    n = length(entries)
    if n == 0
        set_string!(
            buf, area.x + 1, area.y + 1,
            "◌ NO SIGNAL — press [r] refresh or [g] actor",
            tstyle(:text_dim);
            max_x = right(area),
        )
        return 0
    end

    visible_cards = max(1, (area.height + 1) ÷ FEED_CARD_STRIDE)
    sel = clamp(selected, 1, n)
    if sel - 1 < offset
        offset = sel - 1
    elseif sel > offset + visible_cards
        offset = sel - visible_cards
    end
    offset = clamp(offset, 0, max(0, n - visible_cards))

    needs_sb = n > visible_cards && area.width > 10
    card_w = needs_sb ? area.width - 2 : area.width
    max_cx = area.x + card_w - 1

    sel_bg = _card_selected_bg()
    glass_bg = _crt_glass_bg()

    # Pulsing phosphor rail for active card
    rail_rgb = to_rgb(focused ? theme().accent : theme().primary)
    if animations_enabled()
        p = pulse(tick; period = 72, lo = 0.0, hi = 0.28)
        rail_rgb = brighten(rail_rgb, p)
    end
    sel_rail_s = Style(fg = rail_rgb, bg = sel_bg, bold = true)
    dim_rail_s = Style(fg = theme().border, dim = true)

    for slot in 0:(visible_cards - 1)
        idx = offset + slot + 1
        idx > n && break
        y0 = area.y + slot * FEED_CARD_STRIDE
        y0 + 2 > bottom(area) && break

        entry = entries[idx]
        post = entry.post
        rec = post.record
        is_sel = (idx == sel)

        # Selected card gets a warm luminous phosphor wash; unselected cards inherit CRT scanlines!
        if is_sel
            for dy in 0:2
                row = y0 + dy
                for col in area.x:max_cx
                    set_char!(buf, col, row, ' ', Style(bg = sel_bg))
                end
                set_char!(buf, area.x, row, '┃', sel_rail_s)
            end
        else
            for dy in 0:2
                set_char!(buf, area.x, y0 + dy, '│', dim_rail_s)
            end
        end

        cbg = is_sel ? sel_bg : NoColor()
        cx0 = area.x + 2
        inner_w = max(4, max_cx - cx0 + 1)

        # Row 1: Semantic glyph + Display Name + @handle + right-aligned relative time
        glyph, g_field = if entry.is_pinned
            ("★ ", :warning)
        elseif !isnothing(entry.reposted_by)
            ("↻ ", :success)
        elseif !isnothing(entry.reply_parent_handle)
            ("↩ ", :accent)
        else
            ("◈ ", :primary)
        end
        rel = format_relative_time(post.indexedAt)
        rel_w = isempty(rel) ? 0 : textwidth(rel) + 1
        hdr_max = max(cx0, max_cx - rel_w)

        cx = set_string!(buf, cx0, y0, glyph, Style(fg = getfield(theme(), g_field), bg = cbg, bold = true); max_x = hdr_max)
        disp = strip(something(post.author.displayName, ""))
        if !isempty(disp) && cx < hdr_max - 6
            d_str = truncate_chars(disp, min(16, max(4, hdr_max - cx - 6)))
            cx = set_string!(buf, cx, y0, d_str * " ", Style(fg = theme().text_bright, bg = cbg, bold = is_sel); max_x = hdr_max)
        end
        if cx <= hdr_max
            h_str = "@" * truncate_chars(String(post.author.handle), max(4, hdr_max - cx))
            set_string!(buf, cx, y0, h_str, Style(fg = theme().accent, bg = cbg, bold = is_sel); max_x = hdr_max)
        end
        if !isempty(rel)
            set_string!(buf, max_cx - textwidth(rel) + 1, y0, rel, Style(fg = theme().text_dim, bg = cbg); max_x = max_cx)
        end

        # Row 2: Spacious full-width post snippet
        snip = if rec isa API.AppBskyFeedPost
            s = safe_one_line(rec.text)
            isempty(s) ? "(media / quote post)" : s
        else
            "<$(something(lexicon_type(rec), "record"))>"
        end
        body_fg = is_sel ? theme().text_bright : theme().text
        set_string!(buf, cx0, y0 + 1, truncate_chars(snip, inner_w), Style(fg = body_fg, bg = cbg); max_x = max_cx)

        # Row 3: Engagement counts + bookmark indicator + tactile embed chip
        liked = !isnothing(post.viewer) && !isnothing(post.viewer.like)
        reposted = !isnothing(post.viewer) && !isnothing(post.viewer.repost)
        bookmarked = string(post.uri) in bookmarked_uris
        badge = embed_badge(post.embed)
        badge_w = isempty(badge) ? 0 : textwidth(badge) + 3
        stat_max = max(cx0, max_cx - badge_w)

        sx = cx0
        sx = set_string!(
            buf, sx, y0 + 2,
            (liked ? "♥ " : "♡ ") * format_count(post.likeCount) * "   ",
            Style(fg = liked ? theme().error : theme().text_dim, bg = cbg, bold = liked);
            max_x = stat_max,
        )
        sx = set_string!(
            buf, sx, y0 + 2,
            "↻ " * format_count(post.repostCount) * "   ",
            Style(fg = reposted ? theme().success : theme().text_dim, bg = cbg, bold = reposted);
            max_x = stat_max,
        )
        sx = set_string!(
            buf, sx, y0 + 2,
            "💬 " * format_count(post.replyCount),
            Style(fg = theme().text_dim, bg = cbg);
            max_x = stat_max,
        )
        if bookmarked
            set_string!(
                buf, sx + 2, y0 + 2,
                "⚑",
                Style(fg = theme().warning, bg = cbg, bold = true);
                max_x = stat_max,
            )
        end

        if !isempty(badge) && max_cx - badge_w + 2 >= cx0
            bf = _embed_badge_field(post.embed)
            pill = " $badge "
            set_string!(buf, max_cx - textwidth(pill) + 1, y0 + 2, pill, _chip_style(bf; bold = true); max_x = max_cx)
        end

        # Row 4: Whisper-quiet CRT scanline divider between cards
        sep_y = y0 + 3
        if sep_y <= bottom(area) && idx < n
            for col in area.x:max_cx
                set_char!(buf, col, sep_y, SCANLINE, Style(fg = theme().border, dim = true))
            end
        end
    end

    if needs_sb
        sb_rect = Rect(right(area), area.y, 1, area.height)
        render(
            Scrollbar(
                n, visible_cards, offset;
                style = Style(fg = theme().text_dim, bg = glass_bg, dim = true),
                thumb_style = Style(fg = focused ? theme().accent : theme().primary, bg = glass_bg),
            ),
            sb_rect,
            buf,
        )
    end
    return offset
end

function feed_entry_to_list_item(entry::FeedEntry)::ListItem
    post = entry.post
    rec = post.record
    handle = String(post.author.handle)
    rel = format_relative_time(post.indexedAt)
    snippet = rec isa API.AppBskyFeedPost ? safe_one_line(rec.text) : "<record>"
    return ListItem("@$handle · $rel │ $(truncate_chars(snippet, 48))", tstyle(:text))
end

# ── Post Detail Inspector (Inside PVM-14 CRT Monitor) ───────────────

function post_detail_lines(entry::FeedEntry; bookmarked::Bool = false)::Vector{Vector{Span}}
    post = entry.post
    author = post.author
    rec = post.record
    lines = Vector{Vector{Span}}()

    dim_s = tstyle(:text_dim)
    scan_s = tstyle(:border, dim = true)

    if entry.is_pinned
        push!(lines, [Span(" ★ PINNED POST ", _chip_style(:warning))])
        push!(lines, Span[])
    end
    if !isnothing(entry.reposted_by)
        push!(lines, [
            Span(" ↻ REPOST ", _chip_style(:success)),
            Span(" by ", dim_s),
            Span("@$(entry.reposted_by)", tstyle(:success, bold = true, hyperlink = bsky_profile_url(entry.reposted_by))),
        ])
        push!(lines, Span[])
    end
    if !isnothing(entry.reply_parent_handle)
        push!(lines, [
            Span(" ↩ REPLY ", _chip_style(:accent)),
            Span(" to ", dim_s),
            Span("@$(entry.reply_parent_handle)", tstyle(:accent, bold = true, hyperlink = bsky_profile_url(entry.reply_parent_handle))),
        ])
        push!(lines, Span[])
    end

    # Author monogram card header
    disp = strip(something(author.displayName, ""))
    mono = _monogram(disp, String(author.handle))
    rel = format_relative_time(post.indexedAt)
    hdr = Span[
        Span(" $mono ", _inverted_pill_style(:primary)),
        Span("  ", dim_s),
    ]
    if !isempty(disp)
        push!(hdr, Span(disp, tstyle(:title, bold = true)))
        push!(hdr, Span("  ", dim_s))
    end
    push!(hdr, Span("@$(author.handle)", tstyle(:accent, bold = true, hyperlink = bsky_profile_url(author.handle))))
    isempty(rel) || push!(hdr, Span("  ·  $rel", dim_s))
    push!(lines, hdr)

    push!(lines, [
        Span("     " * String(author.did), dim_s),
        Span("   ", dim_s),
        Span(" bsky.app ↗ ", _chip_style(:primary; bold = false, hyperlink = bsky_post_url(post))),
    ])
    push!(lines, [Span(repeat(string(SCANLINE), 52), scan_s)])
    push!(lines, Span[])

    if rec isa API.AppBskyFeedPost
        append!(lines, richtext_to_span_lines(rec.text, rec.facets))
    else
        push!(lines, [Span("<non-post record: $(something(lexicon_type(rec), typeof(rec)))>", dim_s)])
    end

    if !isnothing(post.embed)
        push!(lines, Span[])
        append!(lines, embed_to_span_lines(post.embed))
    end

    # Tactile engagement pills
    push!(lines, Span[])
    push!(lines, [Span(repeat(string(SCANLINE), 52), scan_s)])
    liked = !isnothing(post.viewer) && !isnothing(post.viewer.like)
    reposted = !isnothing(post.viewer) && !isnothing(post.viewer.repost)
    push!(lines, [
        Span(liked ? " ♥ $(format_count(post.likeCount)) likes " : " ♡ $(format_count(post.likeCount)) likes ",
             liked ? _chip_style(:error) : Style(fg = theme().text, bg = _pill_bg(:border))),
        Span("  ", dim_s),
        Span(" ↻ $(format_count(post.repostCount)) reposts ",
             reposted ? _chip_style(:success) : Style(fg = theme().text, bg = _pill_bg(:border))),
        Span("  ", dim_s),
        Span(" 💬 $(format_count(post.replyCount)) replies ",
             Style(fg = theme().text, bg = _pill_bg(:border))),
        Span("  ", dim_s),
        Span(" ❝ $(format_count(post.quoteCount)) quotes ",
             Style(fg = theme().text, bg = _pill_bg(:border))),
        bookmarked ? Span("  ⚑ SAVED ", _chip_style(:warning)) : Span("", dim_s),
    ])

    push!(lines, Span[])
    push!(lines, [Span("URI   ", tstyle(:primary)), Span(string(post.uri), dim_s)])
    push!(lines, [Span("CID   ", tstyle(:primary)), Span(post.cid, dim_s)])
    push!(lines, [Span("TIME  ", tstyle(:primary)), Span(post.indexedAt, dim_s)])
    if rec isa API.AppBskyFeedPost && !isnothing(rec.langs) && !isempty(rec.langs)
        push!(lines, [Span("LANG  ", tstyle(:primary)), Span(join(rec.langs, ", "), dim_s)])
    end
    if !isnothing(post.labels) && !isempty(post.labels)
        lbls = join([l.val for l in post.labels], ", ")
        push!(lines, [Span("LABEL ", tstyle(:warning)), Span(" $lbls ", _chip_style(:warning))])
    end

    push!(lines, Span[])
    push!(lines, [
        Span(" ↵/t ", _keycap_style()), Span(" Thread  ", dim_s),
        Span(" o ", _keycap_style()), Span(" Profile  ", dim_s),
        Span(" p ", _keycap_style()), Span(" Reply  ", dim_s),
        Span(" Q ", _keycap_style()), Span(" Quote  ", dim_s),
        Span(" B ", _keycap_style()), Span(" Bookmark  ", dim_s),
        Span(" i ", _keycap_style()), Span(" Media", dim_s),
    ])
    return lines
end

# ── Thread Railway Tree (Inside VT-AT220 Terminal) ──────────────────

function _collect_ancestors(node)::Vector{Any}
    anc = Any[]
    cur = node isa API.AppBskyFeedDefsThreadViewPost ? node.parent : nothing
    guard = 0
    while !isnothing(cur) && guard < 32
        guard += 1
        pushfirst!(anc, cur)
        cur = cur isa API.AppBskyFeedDefsThreadViewPost ? cur.parent : nothing
    end
    return anc
end

function _render_thread_post!(
    lines::Vector{Vector{Span}},
    posts_out::Vector{API.AppBskyFeedDefsPostView},
    node,
    prefix::String,
    branch::String,
    child_prefix::String;
    is_focal::Bool = false,
)
    dim_s = tstyle(:text_dim)
    rail_s = is_focal ? tstyle(:accent, bold = true) : tstyle(:border)

    if node isa API.AppBskyFeedDefsThreadViewPost
        post = node.post
        push!(posts_out, post)
        author = post.author
        disp = strip(something(author.displayName, ""))
        rel = format_relative_time(post.indexedAt)
        rec = post.record

        hdr = Span[Span(prefix * branch, rail_s)]
        if is_focal
            push!(hdr, Span(" ★ FOCAL ", _inverted_pill_style(:warning)))
            push!(hdr, Span(" ", dim_s))
        end
        if !isempty(disp)
            push!(hdr, Span(disp * " ", is_focal ? tstyle(:title, bold = true) : tstyle(:text_bright, bold = true)))
        end
        push!(hdr, Span("@$(author.handle)", tstyle(:accent, bold = is_focal, hyperlink = bsky_profile_url(author.handle))))
        push!(hdr, Span(" · $rel  ", dim_s))
        push!(hdr, Span("♥$(format_count(post.likeCount)) ↻$(format_count(post.repostCount)) 💬$(format_count(post.replyCount))", dim_s))
        push!(lines, hdr)

        body_prefix = Span[Span(child_prefix, rail_s)]
        if rec isa API.AppBskyFeedPost
            append!(lines, richtext_to_span_lines(rec.text, rec.facets; prefix_spans = body_prefix))
        else
            push!(lines, vcat(body_prefix, [Span("<record>", dim_s)]))
        end

        if !isnothing(post.embed)
            append!(lines, embed_to_span_lines(post.embed; indent = child_prefix))
        end
        push!(lines, [Span(child_prefix, rail_s)])

        if !isnothing(node.replies) && !isempty(node.replies)
            nrep = length(node.replies)
            for (i, rep) in enumerate(node.replies)
                last_child = (i == nrep)
                b = last_child ? "╰─ " : "├─ "
                cp = child_prefix * (last_child ? "   " : "│  ")
                _render_thread_post!(lines, posts_out, rep, child_prefix, b, cp; is_focal = false)
            end
        end
    elseif node isa API.AppBskyFeedDefsNotFoundPost
        push!(lines, [Span(prefix * branch, rail_s), Span("◌ [Post not found: $(node.uri)]", dim_s)])
    elseif node isa API.AppBskyFeedDefsBlockedPost
        push!(lines, [Span(prefix * branch, rail_s), Span("◌ [Blocked post: $(node.uri)]", dim_s)])
    else
        push!(lines, [Span(prefix * branch, rail_s), Span("◌ [Unavailable thread item]", dim_s)])
    end
end

function thread_to_span_lines(thread_root)::Tuple{Vector{Vector{Span}}, Vector{API.AppBskyFeedDefsPostView}}
    lines = Vector{Vector{Span}}()
    posts_out = API.AppBskyFeedDefsPostView[]
    dim_s = tstyle(:text_dim)
    rail_s = tstyle(:border)

    ancestors = _collect_ancestors(thread_root)
    if !isempty(ancestors)
        push!(lines, [Span(" ▲ Parent Context ($(length(ancestors))) ", _chip_style(:primary))])
        push!(lines, Span[])
        for anc in ancestors
            if anc isa API.AppBskyFeedDefsThreadViewPost
                post = anc.post
                push!(posts_out, post)
                rel = format_relative_time(post.indexedAt)
                push!(lines, [
                    Span("┃ ", rail_s),
                    Span("@$(post.author.handle)", tstyle(:accent, bold = true, hyperlink = bsky_profile_url(post.author.handle))),
                    Span(" · $rel  ♥$(format_count(post.likeCount))", dim_s),
                ])
                if post.record isa API.AppBskyFeedPost
                    append!(lines, richtext_to_span_lines(post.record.text, post.record.facets; prefix_spans = [Span("┃ ", rail_s)]))
                end
                push!(lines, [Span("┃", rail_s)])
            else
                push!(lines, [Span("┃ ", rail_s), Span("◌ [Parent unavailable]", dim_s)])
            end
        end
        push!(lines, [Span(" ▼ Focal Post & Replies ", _chip_style(:accent))])
        push!(lines, Span[])
    end

    _render_thread_post!(lines, posts_out, thread_root, "", "", "  "; is_focal = true)
    return lines, posts_out
end

# ── Profile Dossier (Inside IBM 3270 Identity Terminal) ─────────────

function profile_to_span_lines(
    prof::API.AppBskyActorDefsProfileViewDetailed,
    id_info::Union{ATProto.Identity.ResolvedIdentity, Nothing} = nothing,
)::Vector{Vector{Span}}
    lines = Vector{Vector{Span}}()
    dim_s = tstyle(:text_dim)
    border_s = tstyle(:accent)
    scan_s = tstyle(:border, dim = true)

    disp = strip(something(prof.displayName, ""))
    mono = _monogram(disp, String(prof.handle))
    hdr = Span[
        Span(" $mono ", _inverted_pill_style(:warning)),
        Span("  ", dim_s),
    ]
    if !isempty(disp)
        push!(hdr, Span(disp, tstyle(:title, bold = true)))
        push!(hdr, Span("   ", dim_s))
    end
    push!(hdr, Span("@$(prof.handle)", tstyle(:accent, bold = true, hyperlink = bsky_profile_url(prof.handle))))
    push!(hdr, Span("   ", dim_s))
    push!(hdr, Span(" bsky.app ↗ ", _chip_style(:primary; bold = false, hyperlink = bsky_profile_url(prof.handle))))
    push!(lines, hdr)

    if !isnothing(prof.viewer)
        badges = Span[Span("     ", dim_s)]
        if !isnothing(prof.viewer.following)
            push!(badges, Span(" ✓ FOLLOWING ", _chip_style(:success)))
            push!(badges, Span(" ", dim_s))
        end
        if !isnothing(prof.viewer.followedBy)
            push!(badges, Span(" ◈ FOLLOWS YOU ", _chip_style(:accent)))
            push!(badges, Span(" ", dim_s))
        end
        if something(prof.viewer.muted, false)
            push!(badges, Span(" ◌ MUTED ", _chip_style(:warning)))
            push!(badges, Span(" ", dim_s))
        end
        if !isnothing(prof.viewer.blocking)
            push!(badges, Span(" ✕ BLOCKING ", _chip_style(:error)))
        end
        length(badges) > 1 && push!(lines, badges)
    end

    push!(lines, Span[])
    push!(lines, [
        Span(" FOLLOWERS ", _chip_style(:primary)),
        Span(" $(format_count(prof.followersCount))  ", tstyle(:text_bright, bold = true)),
        Span(" FOLLOWING ", _chip_style(:accent)),
        Span(" $(format_count(prof.followsCount))  ", tstyle(:text_bright, bold = true)),
        Span(" POSTS ", _chip_style(:warning)),
        Span(" $(format_count(prof.postsCount))", tstyle(:text_bright, bold = true)),
    ])
    if !isnothing(prof.createdAt)
        push!(lines, [Span("Joined  ", dim_s), Span(first(prof.createdAt, 10), tstyle(:text))])
    end

    push!(lines, Span[])
    push!(lines, [Span("◈ BIO  ", tstyle(:title, bold = true)), Span(repeat(string(SCANLINE), 48), scan_s)])
    if !isnothing(prof.description) && !isempty(strip(prof.description))
        bio_facets = detect_facets(prof.description)
        append!(lines, richtext_to_span_lines(prof.description, bio_facets))
    else
        push!(lines, [Span("(no bio)", dim_s)])
    end

    push!(lines, Span[])
    push!(lines, [Span("╔═ ", border_s), Span(" ◈ AT PROTOCOL IDENTITY CERTIFICATE ", _chip_style(:accent)), Span(" " * "═"^26, border_s)])
    push!(lines, [Span("║ ", border_s), Span("DID          ", dim_s), Span(string(prof.did), tstyle(:text_bright, bold = true))])
    if !isnothing(id_info)
        status_span = if id_info.handle_verified
            Span(" ✓ Verified · Handle ↔ DID bidirectional match ", _chip_style(:success))
        else
            Span(" ⚠ Unverified handle claim ", _chip_style(:warning))
        end
        push!(lines, [Span("║ ", border_s), Span("Status       ", dim_s), status_span])
        push!(lines, [Span("║ ", border_s), Span("PDS          ", dim_s), Span(something(id_info.pds, "unknown"), tstyle(:primary, bold = true))])
        sk = id_info.signing_key
        key_str = if isnothing(sk)
            "unknown"
        else
            pubk = something(sk.publicKeyMultibase, sk.id)
            "$(pubk) ($(sk.type))"
        end
        push!(lines, [Span("║ ", border_s), Span("Signing Key  ", dim_s), Span(truncate_chars(key_str, 72), dim_s)])
    else
        push!(lines, [Span("║ ", border_s), Span("Status       ", dim_s), Span("◌ Resolving DID document & handle…", dim_s)])
    end
    push!(lines, [Span("╚" * "═"^65, border_s)])

    push!(lines, Span[])
    push!(lines, [
        Span(" f ", _keycap_style()), Span(" Load Feed  ", dim_s),
        Span(" F ", _keycap_style()), Span(" Follow/Unfollow  ", dim_s),
        Span(" M ", _keycap_style()), Span(" Mute  ", dim_s),
        Span(" i ", _keycap_style()), Span(" Media  ", dim_s),
        Span(" r ", _keycap_style()), Span(" Refresh", dim_s),
    ])
    return lines
end

# ── Notifications, Chat DMs & Saved Feeds Renderers ─────────────────

function _notif_badge(reason::AbstractString)::Tuple{String, Symbol}
    reason == "like"    && return (" ♥ LIKE ", :error)
    reason == "repost"  && return (" ↻ RPST ", :success)
    reason == "follow"  && return (" + FLW  ", :accent)
    reason == "mention" && return (" @ MNTN ", :primary)
    reason == "reply"   && return (" ↩ RPLY ", :accent)
    reason == "quote"   && return (" ❝ QUOT ", :warning)
    return (" ◈ $(uppercase(first(String(reason), 4))) ", :secondary)
end

function notif_to_list_item(n::API.AppBskyNotificationListNotificationsNotification)::ListItem
    badge, _ = _notif_badge(n.reason)
    mark = n.isRead ? " " : "●"
    rel = format_relative_time(n.indexedAt)
    return ListItem("$mark$badge @$(n.author.handle) · $rel", n.isRead ? tstyle(:text_dim) : tstyle(:text_bright))
end

function notifs_to_span_lines(
    notifs::Vector{API.AppBskyNotificationListNotificationsNotification},
    selected::Int,
)::Vector{Vector{Span}}
    lines = Vector{Vector{Span}}()
    dim_s = tstyle(:text_dim)
    sel_i = clamp(selected, 1, max(1, length(notifs)))

    for (i, n) in enumerate(notifs)
        is_sel = (i == sel_i)
        badge, bfield = _notif_badge(n.reason)
        rel = format_relative_time(n.indexedAt)
        rail = is_sel ? Span("┃ ", tstyle(:accent, bold = true)) : Span("│ ", tstyle(:border, dim = true))
        unread_dot = n.isRead ? Span("  ", dim_s) : Span("● ", tstyle(:error, bold = true))
        disp = strip(something(n.author.displayName, ""))
        who = isempty(disp) ? "@$(n.author.handle)" : "$disp (@$(n.author.handle))"
        push!(lines, Span[
            rail,
            unread_dot,
            Span(badge, _chip_style(bfield)),
            Span("  ", dim_s),
            Span(who, is_sel ? tstyle(:text_bright, bold = true, hyperlink = bsky_profile_url(n.author.handle)) :
                              tstyle(:accent, hyperlink = bsky_profile_url(n.author.handle))),
            Span("  ·  $rel", dim_s),
        ])

        snip = if n.record isa API.AppBskyFeedPost
            safe_one_line(n.record.text)
        elseif !isnothing(n.reasonSubject)
            "Target: $(n.reasonSubject)"
        else
            ""
        end
        if !isempty(snip)
            push!(lines, Span[
                rail,
                Span("    ", dim_s),
                Span(truncate_chars(snip, 88), is_sel ? tstyle(:text_bright) : tstyle(:text)),
            ])
        end
        push!(lines, Span[Span(repeat(string(SCANLINE), 64), tstyle(:border, dim = true))])
    end
    return lines
end

function convo_peer_label(convo::API.ChatBskyConvoDefsConvoView, my_did::AbstractString)::String
    peers = [m for m in convo.members if String(m.did) != String(my_did)]
    shown = isempty(peers) ? convo.members : peers
    isempty(shown) && return convo.id
    parts = [isempty(strip(something(p.displayName, ""))) ? "@$(p.handle)" : "$(p.displayName) (@$(p.handle))" for p in shown]
    return join(parts, ", ")
end

function convo_to_list_item(convo::API.ChatBskyConvoDefsConvoView, my_did::AbstractString)::ListItem
    peer = truncate_chars(convo_peer_label(convo, my_did), 26)
    unread = convo.unreadCount > 0 ? " ($(convo.unreadCount))" : ""
    icon = convo.unreadCount > 0 ? "● " : convo.muted ? "◌ " : "◈ "
    return ListItem("$icon$peer$unread", convo.unreadCount > 0 ? tstyle(:text_bright, bold = true) : tstyle(:text))
end

function chat_messages_to_span_lines(
    convo::API.ChatBskyConvoDefsConvoView,
    messages::Vector{Any},
    my_did::AbstractString,
)::Vector{Vector{Span}}
    lines = Vector{Vector{Span}}()
    dim_s = tstyle(:text_dim)
    handles = Dict{String, String}(String(m.did) => String(m.handle) for m in convo.members)

    for msg in messages
        if msg isa API.ChatBskyConvoDefsMessageView
            s_did = String(msg.sender.did)
            is_me = (s_did == String(my_did))
            who = is_me ? "YOU" : "@" * get(handles, s_did, truncate_chars(s_did, 18))
            rel = format_relative_time(msg.sentAt)
            chip_field = is_me ? :success : :accent
            push!(lines, Span[
                Span(" $who ", _chip_style(chip_field)),
                Span("  $rel", dim_s),
            ])
            prefix = Span[Span(is_me ? "  ┃ " : "  │ ", tstyle(chip_field))]
            append!(lines, richtext_to_span_lines(msg.text, msg.facets; prefix_spans = prefix))
            push!(lines, Span[])
        elseif msg isa API.ChatBskyConvoDefsDeletedMessageView
            push!(lines, Span[Span("  ◌ [message deleted]", dim_s)])
            push!(lines, Span[])
        end
    end
    return lines
end

function saved_feed_to_list_item(sf)::ListItem
    pin = sf.pinned ? "★ " : "  "
    return ListItem("$pin$(sf.label)", sf.pinned ? tstyle(:text_bright, bold = true) : tstyle(:text))
end
