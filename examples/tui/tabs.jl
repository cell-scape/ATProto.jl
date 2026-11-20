# tabs.jl — Retro-future CRT deck chrome, status bar, and all 6 tab views.

function _render_deck_header!(m::BlueskyModel, rect::Rect, buf::Buffer)
    (rect.width < 10 || rect.height < 1) && return
    y = rect.y
    c1 = color_lerp(_canvas_bg_rgb(), to_rgb(theme().primary), light_mode() ? 0.14 : 0.22)
    c2 = _canvas_bg_rgb()
    fill_gradient!(buf, rect, c1, c2; direction = :horizontal)

    cx = rect.x + 1
    rx = right(rect) - 1
    cx = set_string!(buf, cx, y, " ◈ BSKY·DECK ", _inverted_pill_style(:primary); max_x = rx)
    cx = set_string!(buf, cx, y, "  ATProto.jl ", Style(fg = theme().title, bold = true); max_x = rx)

    is_busy = m.queue.active[] > (m.timer_token === nothing ? 0 : 1)
    if is_busy
        spin = SPINNER_DOTS[mod1((m.tick ÷ 3) + 1, length(SPINNER_DOTS))]
        cx = set_string!(buf, cx, y, " $spin SYNC ", _chip_style(:accent); max_x = rx)
    else
        led_rgb = to_rgb(m.firehose_running ? theme().success : theme().accent)
        if animations_enabled()
            b = breathe(m.tick; period = 110)
            led_rgb = brighten(led_rgb, b * 0.35)
        end
        cx = set_string!(buf, cx, y, "◉", Style(fg = led_rgb, bold = true); max_x = rx)
    end

    clock_str = Dates.format(now(UTC), dateformat"HH:MM:SS") * "Z"
    right_spans = if is_authenticated(m.agent)
        sess = session(m.agent)
        h = isnothing(sess) ? "authenticated" : "@$(sess.handle)"
        spans = Span[]
        if m.notifs_unread > 0
            push!(spans, Span(" 🔔 $(m.notifs_unread) ", _chip_style(:error)))
            push!(spans, Span(" ", Style(fg = theme().text_dim)))
        end
        if m.chat_unread_total > 0
            push!(spans, Span(" ✉ $(m.chat_unread_total) ", _chip_style(:primary)))
            push!(spans, Span(" ", Style(fg = theme().text_dim)))
        end
        push!(spans, Span(" ● $h ", _chip_style(:success)))
        push!(spans, Span("  $clock_str ", Style(fg = theme().text_dim)))
        spans
    else
        Span[
            Span(" ○ Public AppView ", _chip_style(:accent; bold = false)),
            Span(" ", Style(fg = theme().text_dim)),
            Span(" L ", _keycap_style()),
            Span(" Login  $clock_str ", Style(fg = theme().text_dim)),
        ]
    end
    rw = sum(textwidth(s.content) for s in right_spans; init = 0)
    rx2 = max(cx + 2, right(rect) - rw + 1)
    for sp in right_spans
        rx2 > right(rect) && break
        rx2 = set_string!(buf, rx2, y, sp.content, sp.style; max_x = right(rect))
    end
end

function _render_tab_strip!(m::BlueskyModel, rect::Rect, buf::Buffer)
    render(m.tabs, rect, buf)
    if rect.height >= 3 && rect.width > 94
        y_mid = rect.y + 1
        scan_lbl = m.scanlines ? "▤ CRT" : "▢ LCD"
        wave_lbl = m.ambient_bg ? "≈ Waves" : "◌ Flat"
        badge = " $scan_lbl · $wave_lbl · ◈ $(theme().name) "
        tx = right(rect) - textwidth(badge)
        if tx > rect.x + 86
            set_string!(buf, tx, y_mid, badge, Style(fg = theme().text_dim); max_x = right(rect) - 1)
        end
    end
end

function _render_feed_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    cols = split_layout(m.feed_split, area)
    m.rect_feed_list = cols[1]
    m.rect_feed_detail = cols[2]

    list_title = if m.feed_mode === :timeline
        "Timeline ($(length(m.feed_entries)))"
    elseif m.feed_mode === :search
        "⌕ $(truncate_chars(m.feed_query, 14)) ($(length(m.feed_entries)))"
    elseif m.feed_mode === :bookmarks
        "⚑ Bookmarks ($(length(m.feed_entries)))"
    elseif m.feed_mode === :saved_feed || m.feed_mode === :list_feed
        "$(truncate_chars(m.feed_source_label, 16)) ($(length(m.feed_entries)))"
    else
        "@$(truncate_chars(m.feed_actor, 16)) ($(length(m.feed_entries)))"
    end
    more_hint = isnothing(m.feed_cursor) ? "[s] Feeds" : "[n] More · [s] Feeds"

    is_busy = m.queue.active[] > (m.timer_token === nothing ? 0 : 1)
    n_posts = length(m.feed_entries)
    sel_i = n_posts == 0 ? 0 : clamp(m.feed_list.selected, 1, n_posts)
    trk_str = @sprintf(" TRK %02d/%02d ", sel_i, n_posts)
    drive_led_sty = Style(fg = _led_rgb(is_busy ? :error : :warning, m.tick; active = is_busy), bold = true)
    pc_chin = Span[
        Span("[▬▬▬▬", tstyle(:text_dim)),
        Span("●", drive_led_sty),
        Span("▬▬▬▬]", tstyle(:text_dim)),
        Span(trk_str, tstyle(:primary, bold = true)),
    ]

    cards_inner = render_crt_monitor!(
        buf, cols[1];
        model_tag = "AT-5150",
        title = list_title,
        title_right = more_hint,
        chin_left = pc_chin,
        pwr_label = is_busy ? "DISK" : "RUN",
        pwr_field = is_busy ? :error : :success,
        pwr_active = true,
        focused = (m.feed_focus === :list),
        tick = m.tick,
        scanlines = m.scanlines,
        outer_box = BOX_HEAVY,
    )
    m.rect_feed_cards_inner = cards_inner
    m.feed_card_offset = render_feed_cards!(
        buf, cards_inner, m.feed_entries, m.feed_list.selected, m.feed_card_offset;
        focused = (m.feed_focus === :list),
        tick = m.tick,
        scanlines = m.scanlines,
        bookmarked_uris = m.bookmarked_uris,
    )

    entry = _selected_entry(m)
    detail_title = isnothing(entry) ? "Post Inspector" : "@$(truncate_chars(String(entry.post.author.handle), 22))"
    pvm_chin = Span[
        Span(" ◉ BRT  ◉ CNT  ", tstyle(:text_dim)),
        Span(m.scanlines ? "[60Hz] " : "[FLAT] ", tstyle(:accent)),
    ]
    detail_inner = render_crt_monitor!(
        buf, cols[2];
        model_tag = "PVM-14",
        title = detail_title,
        title_right = m.feed_focus === :detail ? "SCROLL" : "Tab →",
        chin_left = pvm_chin,
        pwr_label = "PWR",
        pwr_field = :success,
        pwr_active = true,
        focused = (m.feed_focus === :detail),
        tick = m.tick,
        scanlines = m.scanlines,
        outer_box = BOX_HEAVY,
    )
    m.detail_pane.block = nothing
    render(m.detail_pane, detail_inner, buf)

    render_resize_handles!(buf, m.feed_split)
end

function _render_thread_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    m.rect_main_body = area
    title = if m.thread_root isa API.AppBskyFeedDefsThreadViewPost
        "@$(m.thread_root.post.author.handle) ($(length(m.thread_posts)) posts)"
    else
        "Thread Viewer"
    end
    vt_chin = Span[
        Span(" ● ONLINE ", _chip_style(:success)),
        Span("  ● TTY0  ◉ BRT ", tstyle(:text_dim)),
    ]
    inn = render_crt_monitor!(
        buf, area;
        model_tag = "VT-AT220",
        title = title,
        title_right = "Esc:Feed  p:Reply  Q:Quote  i:Media",
        chin_left = vt_chin,
        pwr_label = "PWR",
        pwr_field = :success,
        focused = true,
        tick = m.tick,
        scanlines = m.scanlines,
        pedestal = true,
        accent_field = :accent,
        outer_box = BOX_DOUBLE,
    )
    m.thread_pane.block = nothing
    render(m.thread_pane, inn, buf)
end

function _render_profile_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    m.rect_main_body = area
    title = if !isnothing(m.profile_data)
        "@$(m.profile_data.handle)"
    else
        m.profile_actor
    end
    verified = !isnothing(m.profile_identity) && m.profile_identity.handle_verified
    ibm_chin = Span[
        Span(" ◉ BRT  ◉ CNT  ", tstyle(:text_dim)),
        verified ? Span(" ● ID VERIFIED ", _chip_style(:success)) : Span(" ◌ ID CHECK ", _chip_style(:warning)),
    ]
    inn = render_crt_monitor!(
        buf, area;
        model_tag = "IBM-3270",
        title = title,
        title_right = "F:Follow  M:Mute  i:Media  f:Feed",
        chin_left = ibm_chin,
        pwr_label = "PWR",
        pwr_field = verified ? :success : :warning,
        focused = true,
        tick = m.tick,
        scanlines = m.scanlines,
        pedestal = true,
        accent_field = :warning,
        outer_box = BOX_DOUBLE,
    )
    m.profile_pane.block = nothing
    render(m.profile_pane, inn, buf)
end

function _render_notifs_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    m.rect_main_body = area
    unread_lbl = m.notifs_unread > 0 ? "● $(m.notifs_unread) UNREAD" : "✓ ALL READ"
    unread_sty = m.notifs_unread > 0 ? _chip_style(:error) : _chip_style(:success)
    la_chin = Span[
        Span(" ◉ ALERT ", m.notifs_unread > 0 ? _chip_style(:error) : tstyle(:text_dim)),
        Span("  [↵] Open  [m] Mark Seen  [r] Refresh ", tstyle(:text_dim)),
    ]
    inn = render_crt_monitor!(
        buf, area;
        model_tag = "DEC-LA120",
        title = "Notifications ($(length(m.notifs)))",
        title_right = unread_lbl,
        title_right_style = unread_sty,
        chin_left = la_chin,
        pwr_label = m.notifs_unread > 0 ? "MSG" : "RDY",
        pwr_field = m.notifs_unread > 0 ? :error : :success,
        focused = true,
        tick = m.tick,
        scanlines = m.scanlines,
        pedestal = true,
        accent_field = :error,
        outer_box = BOX_DOUBLE,
    )
    m.notifs_pane.block = nothing
    render(m.notifs_pane, inn, buf)
end

function _render_chat_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    cols = split_layout(m.chat_split, area)
    m.rect_chat_convos = cols[1]
    m.rect_chat_messages = cols[2]
    m.rect_main_body = cols[2]

    convo_chin = Span[
        Span(" ● PROXY ", _chip_style(:primary)),
        Span(" api.bsky.chat ", tstyle(:text_dim)),
    ]
    left_inner = render_crt_monitor!(
        buf, cols[1];
        model_tag = "TTY-DM300",
        title = "Conversations ($(length(m.chat_convos)))",
        title_right = "[r] Sync",
        chin_left = convo_chin,
        pwr_label = "LINK",
        pwr_field = is_authenticated(m.agent) ? :success : :warning,
        pwr_active = is_authenticated(m.agent),
        focused = (m.chat_focus === :convos),
        tick = m.tick,
        scanlines = m.scanlines,
        accent_field = :primary,
        outer_box = BOX_HEAVY,
    )
    if isempty(m.chat_convos)
        msg = is_authenticated(m.agent) ? "◌ Press [r] to load DMs" : "◌ Press [L] to sign in"
        set_string!(buf, left_inner.x, left_inner.y, msg, tstyle(:text_dim); max_x = right(left_inner))
    else
        m.chat_convos_list.focused = (m.chat_focus === :convos)
        render(m.chat_convos_list, left_inner, buf)
    end

    convo = _selected_convo(m)
    my_did = let s = session(m.agent)
        isnothing(s) ? "" : String(s.did)
    end
    chat_title = isnothing(convo) ? "Direct Messages" : convo_peer_label(convo, my_did)
    msg_chin = Span[
        Span(" [c] Send DM  [Tab] Pane  [r] Sync ", tstyle(:text_dim)),
    ]
    right_inner = render_crt_monitor!(
        buf, cols[2];
        model_tag = "TTY-MSG",
        title = chat_title,
        title_right = m.chat_focus === :messages ? "SCROLL" : "[↵] Open",
        chin_left = msg_chin,
        pwr_label = "ENC",
        pwr_field = :accent,
        focused = (m.chat_focus === :messages),
        tick = m.tick,
        scanlines = m.scanlines,
        accent_field = :accent,
        outer_box = BOX_HEAVY,
    )
    m.chat_messages_pane.block = nothing
    render(m.chat_messages_pane, right_inner, buf)

    render_resize_handles!(buf, m.chat_split)
end

function _render_firehose_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    top_h = area.height >= 24 ? 9 : (area.height >= 18 ? 7 : 6)
    rows = split_layout(Layout(Vertical, [Fixed(top_h), Fill(1)]), area)
    top_cols = split_layout(Layout(Horizontal, [Percent(52), Fill(1)]), rows[1])
    m.rect_main_body = rows[2]

    preset = JETSTREAM_PRESETS[m.firehose_preset_idx]
    state_lbl = m.firehose_running ? "◉ LIVE TX" : "◌ STANDBY"
    state_sty = m.firehose_running ? _chip_style(:success) : _chip_style(:warning)
    modem_chin = Span[
        Span(m.firehose_running ? " ● CARR " : " ○ CARR ", m.firehose_running ? _chip_style(:success) : tstyle(:text_dim)),
        Span("  ● RX  ● WS ", tstyle(:text_dim)),
    ]
    stats_inner = render_crt_monitor!(
        buf, top_cols[1];
        model_tag = "JS-MODEM",
        title = "Jetstream Firehose",
        title_right = state_lbl,
        title_right_style = state_sty,
        chin_left = modem_chin,
        pwr_label = m.firehose_running ? "TX" : "STBY",
        pwr_field = m.firehose_running ? :success : :warning,
        pwr_active = m.firehose_running,
        focused = m.firehose_running,
        tick = m.tick,
        scanlines = m.scanlines,
        accent_field = :success,
        outer_box = BOX_HEAVY,
    )
    if stats_inner.height >= 1 && stats_inner.width > 4
        y = stats_inner.y
        cx = stats_inner.x
        mr = right(stats_inner)
        cx = set_string!(buf, cx, y, " SEEN ", _chip_style(:primary); max_x = mr)
        cx = set_string!(buf, cx, y, " $(format_count(m.firehose_total))  ", tstyle(:text_bright, bold = true); max_x = mr)
        cx = set_string!(buf, cx, y, " POST ", _chip_style(:accent); max_x = mr)
        cx = set_string!(buf, cx, y, " $(format_count(m.firehose_posts))  ", tstyle(:text); max_x = mr)
        set_string!(buf, cx, y, "♥$(format_count(m.firehose_likes)) ↻$(format_count(m.firehose_reposts))", tstyle(:text_dim); max_x = mr)

        if stats_inner.height >= 2
            filt = isempty(m.firehose_filter) ? "(all)" : repr(m.firehose_filter)
            set_string!(
                buf, stats_inner.x, y + 1,
                "Preset[C]: $(preset.label) · Filter[/]: $filt",
                tstyle(:text_dim);
                max_x = mr,
            )
        end
        if stats_inner.height >= 3
            cur_str = isnothing(m.firehose_cursor) ? "—" : string(m.firehose_cursor)
            set_string!(buf, stats_inner.x, y + 2, "Cursor: $cur_str", tstyle(:text_dim); max_x = mr)
        end
    end

    cur_rate = isempty(m.firehose_rate_history) ? 0 : round(Int, m.firehose_rate_history[end])
    peak_rate = isempty(m.firehose_rate_history) ? 0 : round(Int, maximum(m.firehose_rate_history))
    scope_chin = Span[
        Span(" ◉ TRIG  ◉ SWP  ", tstyle(:text_dim)),
        Span("1s/DIV ", tstyle(:primary)),
    ]
    spark_inner = render_crt_monitor!(
        buf, top_cols[2];
        model_tag = "TEK-4010",
        title = "Events / sec",
        title_right = "$(cur_rate)/s · pk $(peak_rate)",
        title_right_style = Style(fg = theme().primary, bg = _chassis_bg(), bold = true),
        chin_left = scope_chin,
        pwr_label = "BEAM",
        pwr_field = :accent,
        pwr_active = m.firehose_running,
        focused = false,
        tick = m.tick,
        scanlines = m.scanlines,
        accent_field = :accent,
        outer_box = BOX_HEAVY,
    )
    spark = Sparkline(
        m.firehose_rate_history;
        style = m.firehose_running ? tstyle(:accent) : tstyle(:text_dim),
    )
    render(spark, spark_inner, buf)

    follow_lbl = m.firehose_pane.following ? "AUTO-FOLLOW" : "SCROLLED"
    stream_chin = Span[
        Span(" ◉ BRT  ◉ HOLD  ", tstyle(:text_dim)),
        Span("[Space] Tune  [x] Wipe ", tstyle(:text_dim)),
    ]
    stream_inner = render_crt_monitor!(
        buf, rows[2];
        model_tag = "TTY-LIVE",
        title = "Commits ($(length(m.firehose_items))/$MAX_FIREHOSE_LINES)",
        title_right = follow_lbl,
        title_right_style = m.firehose_pane.following ? _chip_style(:success) : _chip_style(:warning),
        chin_left = stream_chin,
        pwr_label = "CRT",
        pwr_field = :success,
        pwr_active = true,
        focused = !m.firehose_running,
        tick = m.tick,
        scanlines = m.scanlines,
        accent_field = :success,
        outer_box = BOX_DOUBLE,
    )
    m.firehose_pane.block = nothing
    render(m.firehose_pane, stream_inner, buf)
end

function _render_status_bar!(m::BlueskyModel, rect::Rect, buf::Buffer)
    (rect.width < 4 || rect.height < 1) && return
    y = rect.y
    sbg = _surface_bg()
    _fill_surface!(buf, rect, sbg)

    right_spans = Span[]
    rl = rate_limit(m.agent)
    if !isnothing(rl) && !isnothing(rl.remaining) && !isnothing(rl.limit)
        push!(right_spans, Span(" RL:$(rl.remaining)/$(rl.limit) ", _chip_style(:primary; bold = false)))
        push!(right_spans, Span(" ", Style(bg = sbg)))
    end
    push!(right_spans, Span(" ? ", _keycap_style()))
    push!(right_spans, Span(" Help ", Style(fg = theme().text_dim, bg = sbg)))
    push!(right_spans, Span(" ^T ", _keycap_style()))
    push!(right_spans, Span(" Theme ", Style(fg = theme().text_dim, bg = sbg)))
    push!(right_spans, Span(" q ", _keycap_style()))
    push!(right_spans, Span(" Quit ", Style(fg = theme().text_dim, bg = sbg)))

    rw = sum(textwidth(s.content) for s in right_spans; init = 0)
    left_max = max(rect.x, right(rect) - rw - 1)

    if m.status_ttl > 0 && !isempty(m.status_msg)
        field = m.status_kind === :error   ? :error :
                m.status_kind === :warning ? :warning :
                m.status_kind === :success ? :success : :accent
        icon = m.status_kind === :error ? "✕ " : m.status_kind === :warning ? "⚠ " : m.status_kind === :success ? "✓ " : "◈ "
        pill = " $icon$(m.status_msg) "
        set_string!(buf, rect.x + 1, y, pill, _chip_style(field); max_x = left_max)
    else
        pairs = if m.tabs.active == TAB_FEED
            [("j/k", "Nav"), ("↵", "Thread"), ("s", "Feeds"), ("Q", "Quote"), ("B", "Bmark"), ("i", "Media"), ("F", "Follow"), ("P", "Phosphor")]
        elseif m.tabs.active == TAB_THREAD
            [("j/k", "Scroll"), ("Esc", "Feed"), ("p", "Reply"), ("Q", "Quote"), ("i", "Media"), ("r", "Refresh")]
        elseif m.tabs.active == TAB_PROFILE
            [("j/k", "Scroll"), ("F", "Follow"), ("M", "Mute"), ("i", "Media"), ("f", "Feed"), ("r", "Refresh")]
        elseif m.tabs.active == TAB_NOTIFS
            [("j/k", "Nav"), ("↵", "Open"), ("o", "Profile"), ("m", "Mark Seen"), ("n", "More"), ("r", "Refresh")]
        elseif m.tabs.active == TAB_CHAT
            [("j/k", "Nav"), ("↵", "Open"), ("c", "Send DM"), ("Tab", "Pane"), ("r", "Refresh")]
        else
            [("Space", "Tune/Stby"), ("/", "Filter"), ("C", "Preset"), ("x", "Wipe"), ("P", "Phosphor")]
        end
        render_keycap_bar!(buf, rect.x + 1, y, pairs; max_x = left_max, bg = sbg)
    end

    rx2 = max(rect.x, right(rect) - rw + 1)
    for sp in right_spans
        rx2 > right(rect) && break
        rx2 = set_string!(buf, rx2, y, sp.content, sp.style; max_x = right(rect))
    end
end
