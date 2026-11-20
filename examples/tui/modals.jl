# modals.jl — Modal key handlers and floating CRT dialog renderers.

function _open_compose!(
    m::BlueskyModel;
    reply_to::Union{API.AppBskyFeedDefsPostView, Nothing} = nothing,
    quote_of::Union{API.AppBskyFeedDefsPostView, Nothing} = nothing,
)
    set_text!(m.compose_area, "")
    m.compose_area.focused = true
    m.compose_reply_to = reply_to
    m.compose_quote_of = quote_of
    m.modal = :compose
    nothing
end

function _handle_modal_key!(m::BlueskyModel, evt::KeyEvent)
    if evt.key == :escape
        m.modal = :none
        m.compose_reply_to = nothing
        m.compose_quote_of = nothing
        return nothing
    end

    if m.modal === :help
        if evt.key == :enter || (evt.key == :char && evt.char in ('?', 'q'))
            m.modal = :none
        end
        return nothing
    end

    if m.modal === :gallery
        n = length(m.gallery_images)
        if evt.key == :left || (evt.key == :char && evt.char in ('h', 'k'))
            n > 0 && (m.gallery_idx = mod1(m.gallery_idx - 1, n))
        elseif evt.key == :right || (evt.key == :char && evt.char in ('l', 'j', ' '))
            n > 0 && (m.gallery_idx = mod1(m.gallery_idx + 1, n))
        elseif evt.key == :enter || (evt.key == :char && evt.char in ('i', 'q'))
            m.modal = :none
        end
        return nothing
    end

    if m.modal === :feeds
        if evt.key == :enter
            if !isempty(m.saved_feeds)
                idx = clamp(m.saved_feeds_list.selected, 1, length(m.saved_feeds))
                ch = m.saved_feeds[idx]
                m.modal = :none
                m.tabs.active = TAB_FEED
                if ch.kind === :timeline
                    m.feed_mode = :timeline
                elseif ch.kind === :bookmarks
                    m.feed_mode = :bookmarks
                elseif ch.kind === :feed
                    m.feed_mode = :saved_feed
                    m.feed_source_uri = ch.value
                    m.feed_source_label = replace(ch.label, r"^[◈★▤⚑]\s*(Feed:|List:)?\s*" => "")
                elseif ch.kind === :list
                    m.feed_mode = :list_feed
                    m.feed_source_uri = ch.value
                    m.feed_source_label = replace(ch.label, r"^[◈★▤⚑]\s*(Feed:|List:)?\s*" => "")
                else
                    m.feed_mode = :author
                    m.feed_actor = ch.value
                end
                _fetch_feed!(m; append = false)
            else
                m.modal = :none
            end
            return nothing
        end
        handle_key!(m.saved_feeds_list, _nav_key(evt))
        return nothing
    end

    if m.modal === :chat_send
        if evt.key == :enter
            txt = strip(text(m.chat_input))
            set_text!(m.chat_input, "")
            m.modal = :none
            isempty(txt) || _send_chat_message!(m, txt)
            return nothing
        end
        handle_key!(m.chat_input, evt)
        return nothing
    end

    if m.modal === :goto
        if evt.key == :enter
            raw = strip(text(m.goto_input))
            actor = startswith(raw, "@") ? raw[2:end] : raw
            if isempty(actor)
                m.modal = :none
                return nothing
            end
            if !(is_valid_handle(actor) || is_valid_did(actor))
                _notify!(m, "Invalid handle or DID: $actor", :error)
                return nothing
            end
            m.modal = :none
            m.feed_mode = :author
            m.feed_actor = actor
            m.profile_actor = actor
            _fetch_feed!(m; append = false)
            _fetch_profile!(m, actor)
            if m.tabs.active != TAB_PROFILE
                m.tabs.active = TAB_FEED
            end
            return nothing
        end
        handle_key!(m.goto_input, evt)
        return nothing
    end

    if m.modal === :search
        if evt.key == :enter
            q = strip(text(m.search_input))
            m.modal = :none
            if m.tabs.active == TAB_FIREHOSE
                m.firehose_filter = q
                _notify!(m, isempty(q) ? "Firehose filter cleared" : "Firehose filter: $(repr(q))", :info)
            else
                isempty(q) && return nothing
                m.feed_mode = :search
                m.feed_query = q
                m.tabs.active = TAB_FEED
                _fetch_feed!(m; append = false)
            end
            return nothing
        end
        handle_key!(m.search_input, evt)
        return nothing
    end

    if m.modal === :compose
        if evt.key == :ctrl && evt.char == 'd'
            _submit_compose!(m)
            return nothing
        end
        handle_key!(m.compose_area, evt)
        return nothing
    end

    if m.modal === :login
        if is_authenticated(m.agent) && evt.key == :ctrl && evt.char == 'o'
            try logout!(m.agent) catch end
            m.agent = AtpAgent(PUBLIC_APPVIEW)
            m.feed_mode = :author
            m.notifs_unread = 0
            m.chat_unread_total = 0
            empty!(m.notifs)
            empty!(m.chat_convos)
            empty!(m.chat_messages)
            _update_tab_labels!(m)
            m.modal = :none
            _notify!(m, "Signed out — switched to Public AppView", :info)
            _fetch_feed!(m; append = false)
            return nothing
        end
        if evt.key == :tab || evt.key == :backtab || evt.key == :up || evt.key == :down
            m.login_field = m.login_field == 1 ? 2 : 1
            m.login_handle_input.focused = (m.login_field == 1)
            m.login_pass_input.focused = (m.login_field == 2)
            return nothing
        elseif evt.key == :enter
            if m.login_field == 1 && isempty(strip(text(m.login_pass_input)))
                m.login_field = 2
                m.login_handle_input.focused = false
                m.login_pass_input.focused = true
                return nothing
            end
            h = text(m.login_handle_input)
            pw = text(m.login_pass_input)
            set_text!(m.login_pass_input, "")
            m.modal = :none
            _start_login!(m, h, pw)
            return nothing
        end
        if m.login_field == 1
            handle_key!(m.login_handle_input, evt)
        else
            handle_key!(m.login_pass_input, evt)
        end
        return nothing
    end
    nothing
end

function _wrap_modal_text(s::AbstractString, max_w::Int)::Vector{String}
    max_w <= 4 && return [String(s)]
    lines = String[]
    for para in split(String(s), '\n')
        words = split(strip(para))
        if isempty(words)
            push!(lines, "")
            continue
        end
        cur = ""
        for w in words
            cand = isempty(cur) ? String(w) : cur * " " * String(w)
            if textwidth(cand) <= max_w
                cur = cand
            else
                isempty(cur) || push!(lines, cur)
                cur = truncate_chars(String(w), max_w)
            end
        end
        isempty(cur) || push!(lines, cur)
    end
    return isempty(lines) ? [""] : lines
end

function _render_modal!(m::BlueskyModel, area::Rect, buf::Buffer)
    mbg = _modal_bg()

    if m.modal === :goto
        inn = render_floating_modal!(buf, area, 66, 8; title = "Go to Handle or DID", title_right = "ATProto Syntax", tick = m.tick)
        m.goto_input.tick = m.tick
        render(m.goto_input, Rect(inn.x, inn.y + 1, max(1, inn.width), 1), buf)
        raw = strip(text(m.goto_input))
        cleaned = startswith(raw, "@") ? raw[2:end] : raw
        status_y = inn.y + 3
        if !isempty(cleaned)
            if is_valid_did(cleaned)
                set_string!(buf, inn.x, status_y, " ✓ Valid DID ", _chip_style(:success); max_x = right(inn))
            elseif is_valid_handle(cleaned)
                set_string!(buf, inn.x, status_y, " ✓ Valid handle ", _chip_style(:success); max_x = right(inn))
            else
                set_string!(buf, inn.x, status_y, " ✕ Invalid handle or DID syntax ", _chip_style(:error); max_x = right(inn))
            end
        else
            set_string!(buf, inn.x, status_y, "e.g. bsky.app  or  did:plc:z72i7hdynmk6r22z27h6tvur", Style(fg = theme().text_dim, bg = mbg); max_x = right(inn))
        end
        render_keycap_bar!(buf, inn.x, bottom(inn), [("↵", "Load"), ("Esc", "Cancel")]; max_x = right(inn), bg = mbg)

    elseif m.modal === :search
        is_fh = (m.tabs.active == TAB_FIREHOSE)
        inn = render_floating_modal!(
            buf, area, 66, 7;
            title = is_fh ? "Filter Jetstream Firehose" : "Search Bluesky Posts",
            title_right = is_fh ? "substring" : "searchPosts",
            tick = m.tick,
        )
        m.search_input.tick = m.tick
        render(m.search_input, Rect(inn.x, inn.y + 1, max(1, inn.width), 1), buf)
        pairs = is_fh ? [("↵", "Apply (empty clears)"), ("Esc", "Cancel")] : [("↵", "Search"), ("Esc", "Cancel")]
        render_keycap_bar!(buf, inn.x, bottom(inn), pairs; max_x = right(inn), bg = mbg)

    elseif m.modal === :feeds
        h = clamp(length(m.saved_feeds) + 6, 9, 18)
        inn = render_floating_modal!(
            buf, area, 68, h;
            title = "Saved Feeds, Lists & Bookmarks",
            title_right = "$(length(m.saved_feeds)) sources",
            tick = m.tick,
        )
        list_rect = Rect(inn.x, inn.y, max(1, inn.width), max(1, inn.height - 2))
        m.saved_feeds_list.focused = true
        render(m.saved_feeds_list, list_rect, buf)
        render_keycap_bar!(buf, inn.x, bottom(inn), [("j/k", "Select"), ("↵", "Switch Feed"), ("Esc", "Close")]; max_x = right(inn), bg = mbg)

    elseif m.modal === :gallery
        n = length(m.gallery_images)
        idx = clamp(m.gallery_idx, 1, max(1, n))
        inn = render_floating_modal!(
            buf, area, 76, 18;
            title = m.gallery_title,
            title_right = n > 0 ? "$idx / $n" : "0",
            tick = m.tick,
        )
        if n > 0
            img = m.gallery_images[idx]
            y = inn.y
            cx = set_string!(buf, inn.x, y, " ▣ $(img.label) ", _chip_style(:accent); max_x = right(inn))
            cx = set_string!(buf, cx + 1, y, " $(img.dims) ", _chip_style(:primary; bold = false); max_x = right(inn))
            set_string!(buf, cx + 1, y, " open fullsize ↗ ", _chip_style(:success; hyperlink = img.fullsize); max_x = right(inn))

            y += 2
            set_string!(buf, inn.x, y, "ALT TEXT", Style(fg = theme().title, bg = mbg, bold = true); max_x = right(inn))
            y += 1
            alt_text = isempty(strip(img.alt)) ? "(no alt text provided)" : img.alt
            wrapped = _wrap_modal_text(alt_text, max(12, inn.width - 2))
            for wl in wrapped
                y >= bottom(inn) - 3 && break
                set_string!(buf, inn.x, y, wl, Style(fg = theme().text, bg = mbg); max_x = right(inn))
                y += 1
            end

            url_y = bottom(inn) - 2
            set_string!(buf, inn.x, url_y, "URL: " * truncate_chars(img.fullsize, max(10, inn.width - 6)),
                        Style(fg = theme().primary, bg = mbg, underline = true, hyperlink = img.fullsize); max_x = right(inn))
        end
        render_keycap_bar!(buf, inn.x, bottom(inn), [("←/→", "Prev/Next"), ("Esc", "Close")]; max_x = right(inn), bg = mbg)

    elseif m.modal === :chat_send
        convo = _selected_convo(m)
        my_did = let s = session(m.agent); isnothing(s) ? "" : String(s.did) end
        peer = isnothing(convo) ? "Chat" : convo_peer_label(convo, my_did)
        inn = render_floating_modal!(buf, area, 68, 7; title = "Send DM to $peer", title_right = "chat.bsky.convo", tick = m.tick)
        m.chat_input.tick = m.tick
        render(m.chat_input, Rect(inn.x, inn.y + 1, max(1, inn.width), 1), buf)
        render_keycap_bar!(buf, inn.x, bottom(inn), [("↵", "Send"), ("Esc", "Cancel")]; max_x = right(inn), bg = mbg)

    elseif m.modal === :compose
        title = if !isnothing(m.compose_quote_of)
            "Quote @$(m.compose_quote_of.author.handle)"
        elseif !isnothing(m.compose_reply_to)
            "Reply to @$(m.compose_reply_to.author.handle)"
        else
            "Compose Post"
        end
        mode_tag = is_authenticated(m.agent) ? "LIVE PDS" : "DRY-RUN"
        inn = render_floating_modal!(buf, area, 76, 17; title = title, title_right = mode_tag, tick = m.tick)

        cur_y = inn.y
        if !isnothing(m.compose_quote_of)
            qp = m.compose_quote_of
            snip = qp.record isa API.AppBskyFeedPost ? safe_one_line(qp.record.text) : "<post>"
            set_string!(
                buf, inn.x, cur_y,
                "❝ @$(qp.author.handle): $(truncate_chars(snip, max(10, inn.width - 18)))",
                Style(fg = theme().success, bg = mbg);
                max_x = right(inn),
            )
            cur_y += 1
        elseif !isnothing(m.compose_reply_to)
            rp = m.compose_reply_to
            snip = rp.record isa API.AppBskyFeedPost ? safe_one_line(rp.record.text) : "<post>"
            set_string!(
                buf, inn.x, cur_y,
                "↩ @$(rp.author.handle): $(truncate_chars(snip, max(10, inn.width - 18)))",
                Style(fg = theme().text_dim, bg = mbg);
                max_x = right(inn),
            )
            cur_y += 1
        end

        editor_h = max(3, bottom(inn) - cur_y - 4)
        editor_rect = render(
            Block(border_style = tstyle(:border), box = BOX_ROUNDED),
            Rect(inn.x, cur_y, max(1, inn.width), editor_h),
            buf,
        )
        _fill_crt_glass!(buf, editor_rect; scanlines = m.scanlines)
        m.compose_area.tick = m.tick
        render(m.compose_area, editor_rect, buf)

        txt = text(m.compose_area)
        g_len = grapheme_length(txt)
        b_len = byte_length(txt)
        meter_field = (g_len > 300 || b_len > 3000) ? :error : g_len >= 270 ? :warning : :success

        gauge_y = cur_y + editor_h
        if gauge_y <= bottom(inn) - 2
            g_ratio = clamp(g_len / 300.0, 0.0, 1.0)
            gauge = Gauge(
                g_ratio;
                label = " $g_len/300 gr · $b_len/3000 B ",
                filled_style = tstyle(meter_field, bold = true),
                empty_style = Style(fg = theme().border, bg = mbg, dim = true),
                label_style = Style(fg = theme().text_bright, bg = mbg, bold = true),
                tick = m.tick,
            )
            render(gauge, Rect(inn.x, gauge_y, max(1, inn.width), 1), buf)
        end

        facet_y = gauge_y + 1
        if facet_y <= bottom(inn) - 1
            ms = detect_mentions(txt)
            ls = detect_links(txt)
            ts = detect_tags(txt)
            cx = inn.x
            mr = right(inn)
            cx = set_string!(buf, cx, facet_y, "Facets  ", Style(fg = theme().text_dim, bg = mbg); max_x = mr)
            cx = set_string!(buf, cx, facet_y, " $(length(ms)) mentions ", _chip_style(:accent; bold = !isempty(ms)); max_x = mr)
            cx = set_string!(buf, cx, facet_y, " ", Style(bg = mbg); max_x = mr)
            cx = set_string!(buf, cx, facet_y, " $(length(ls)) links ", _chip_style(:primary; bold = !isempty(ls)); max_x = mr)
            cx = set_string!(buf, cx, facet_y, " ", Style(bg = mbg); max_x = mr)
            set_string!(buf, cx, facet_y, " $(length(ts)) tags ", _chip_style(:warning; bold = !isempty(ts)); max_x = mr)
        end

        action_lbl = is_authenticated(m.agent) ? "Publish" : "Dry-run Preview"
        render_keycap_bar!(buf, inn.x, bottom(inn), [("^D", action_lbl), ("↵", "Newline"), ("Esc", "Cancel")]; max_x = right(inn), bg = mbg)

    elseif m.modal === :login
        inn = render_floating_modal!(buf, area, 64, 11; title = "Bluesky Sign In", title_right = "App Password", tick = m.tick)
        m.login_handle_input.tick = m.tick
        render(m.login_handle_input, Rect(inn.x, inn.y + 1, max(1, inn.width), 1), buf)

        pw_y = inn.y + 3
        pw_lbl_s = m.login_field == 2 ? Style(fg = theme().accent, bg = mbg, bold = true) : Style(fg = theme().text_dim, bg = mbg)
        cx = set_string!(buf, inn.x, pw_y, "Password: ", pw_lbl_s; max_x = right(inn))
        masked = repeat("•", length(m.login_pass_input.buffer))
        cx = set_string!(buf, cx, pw_y, masked, Style(fg = theme().text, bg = mbg); max_x = right(inn) - 1)
        if m.login_field == 2 && cx <= right(inn)
            set_char!(buf, cx, pw_y, ' ', Style(fg = Color256(0), bg = theme().accent))
        end

        note_y = inn.y + 5
        if is_authenticated(m.agent)
            sess = session(m.agent)
            h = isnothing(sess) ? "" : "@$(sess.handle)"
            set_string!(buf, inn.x, note_y, " ● Signed in as $h — press ^O to sign out ", _chip_style(:success); max_x = right(inn))
        else
            set_string!(buf, inn.x, note_y, "Tip: create an App Password at bsky.app/settings/app-passwords", Style(fg = theme().text_dim, bg = mbg); max_x = right(inn))
        end
        render_keycap_bar!(buf, inn.x, bottom(inn), [("Tab", "Field"), ("↵", "Sign In"), ("Esc", "Cancel")]; max_x = right(inn), bg = mbg)

    elseif m.modal === :help
        help_lines = [
            ("◈ Navigation", tstyle(:title, bold = true)),
            ("  1–6               Feed / Thread / Profile / Notifs / Chat / Firehose", tstyle(:text)),
            ("  j/k or ↑/↓        Move selection or scroll active CRT pane", tstyle(:text)),
            ("  Tab or ←/→        Switch focus between split panes", tstyle(:text)),
            ("  Mouse Drag        Drag split border to resize (right-click resets)", tstyle(:text)),
            ("  Enter / t         Open thread (or open notification / chat convo)", tstyle(:text)),
            ("  o / f / s         Author profile / Profile feed / Saved Feeds & Bookmarks", tstyle(:text)),
            ("  n / r             Load next cursor page / Refresh active view", tstyle(:text)),
            ("", tstyle(:text)),
            ("◈ Social Actions & Modals", tstyle(:title, bold = true)),
            ("  g / /             Go to Handle or DID / Search posts (or filter firehose)", tstyle(:text)),
            ("  c / p / Q         Compose post (or DM on Chat) / Reply / Quote-Post", tstyle(:text)),
            ("  l / R / B         Like / Repost / Toggle Bookmark (auth)", tstyle(:text)),
            ("  F / M / i         Follow-Unfollow / Mute-Unmute / Image & Alt-Text Gallery", tstyle(:text)),
            ("  T / m / L         Toggle Timeline / Mark Notifs Seen / Sign In (^O Out)", tstyle(:text)),
            ("", tstyle(:text)),
            ("◈ Jetstream & Retro CRT Hardware", tstyle(:title, bold = true)),
            ("  Space / C / x     Connect or Standby / Cycle presets / Clear firehose", tstyle(:text)),
            ("  P / v / b         Cycle CRT phosphor / Toggle scanlines / DotWave", tstyle(:text)),
            ("  Ctrl+T / Ctrl+Y   All 25+ themes / Copy active pane", tstyle(:text)),
        ]
        inn = render_floating_modal!(
            buf, area, 78, length(help_lines) + 5;
            title = "BSKY·DECK Keybindings",
            title_right = "Esc / ?: Close",
            tick = m.tick,
        )
        for (i, (txt, sty)) in enumerate(help_lines)
            y = inn.y + i - 1
            y >= bottom(inn) && break
            set_string!(buf, inn.x, y, txt, Style(fg = sty.fg, bg = mbg, bold = sty.bold); max_x = right(inn))
        end
        render_keycap_bar!(buf, inn.x, bottom(inn), [("Esc", "Close"), ("P", "Phosphor"), ("v", "Scanlines"), ("b", "Waves")]; max_x = right(inn), bg = mbg)
    end
    nothing
end
