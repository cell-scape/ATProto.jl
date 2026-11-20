# events.jl — TaskEvent, KeyEvent, MouseEvent handlers, and top-level view().

function _format_err(e)::String
    if e isa XRPCError
        return "$(e.error): $(isempty(e.message) ? "HTTP $(e.status)" : e.message)"
    elseif e isa AuthError
        return "Auth error: $(e.message)"
    else
        return truncate_chars(sprint(showerror, e), 70)
    end
end

function _update_post_viewer!(m::BlueskyModel, uri::AtUri; like_uri = :unchanged, repost_uri = :unchanged)
    for (i, entry) in enumerate(m.feed_entries)
        p = entry.post
        p.uri == uri || continue
        old_v = p.viewer
        new_like = like_uri === :unchanged ? (isnothing(old_v) ? nothing : old_v.like) : like_uri
        new_repost = repost_uri === :unchanged ? (isnothing(old_v) ? nothing : old_v.repost) : repost_uri
        new_v = API.AppBskyFeedDefsViewerState(
            embeddingDisabled = isnothing(old_v) ? nothing : old_v.embeddingDisabled,
            like = new_like,
            pinned = isnothing(old_v) ? nothing : old_v.pinned,
            replyDisabled = isnothing(old_v) ? nothing : old_v.replyDisabled,
            repost = new_repost,
            threadMuted = isnothing(old_v) ? nothing : old_v.threadMuted,
        )
        d_like = like_uri === :unchanged ? 0 : (isnothing(like_uri) ? -1 : 1)
        d_repost = repost_uri === :unchanged ? 0 : (isnothing(repost_uri) ? -1 : 1)
        new_p = API.AppBskyFeedDefsPostView(
            author = p.author,
            cid = p.cid,
            indexedAt = p.indexedAt,
            record = p.record,
            uri = p.uri,
            embed = p.embed,
            labels = p.labels,
            likeCount = max(0, something(p.likeCount, 0) + d_like),
            quoteCount = p.quoteCount,
            replyCount = p.replyCount,
            repostCount = max(0, something(p.repostCount, 0) + d_repost),
            threadgate = p.threadgate,
            viewer = new_v,
        )
        m.feed_entries[i] = FeedEntry(new_p, entry.reposted_by, entry.is_pinned, entry.reply_parent_handle)
    end
    _rebuild_feed_list!(m)
    nothing
end

function _update_actor_viewer!(m::BlueskyModel, target_did::DID; follow_uri = :unchanged, muted = :unchanged)
    if !isnothing(m.profile_data) && m.profile_data.did == target_did
        p = m.profile_data
        ov = p.viewer
        new_flw = follow_uri === :unchanged ? (isnothing(ov) ? nothing : ov.following) : follow_uri
        new_mut = muted === :unchanged ? (isnothing(ov) ? nothing : ov.muted) : muted
        new_v = API.AppBskyActorDefsViewerState(
            blockedBy = isnothing(ov) ? nothing : ov.blockedBy,
            blocking = isnothing(ov) ? nothing : ov.blocking,
            blockingByList = isnothing(ov) ? nothing : ov.blockingByList,
            followedBy = isnothing(ov) ? nothing : ov.followedBy,
            following = new_flw,
            knownFollowers = isnothing(ov) ? nothing : ov.knownFollowers,
            muted = new_mut,
            mutedByList = isnothing(ov) ? nothing : ov.mutedByList,
        )
        d_flw = follow_uri === :unchanged ? 0 : (isnothing(follow_uri) ? -1 : 1)
        m.profile_data = API.AppBskyActorDefsProfileViewDetailed(
            did = p.did,
            handle = p.handle,
            associated = p.associated,
            avatar = p.avatar,
            banner = p.banner,
            createdAt = p.createdAt,
            description = p.description,
            displayName = p.displayName,
            followersCount = max(0, something(p.followersCount, 0) + d_flw),
            followsCount = p.followsCount,
            indexedAt = p.indexedAt,
            joinedViaStarterPack = p.joinedViaStarterPack,
            labels = p.labels,
            pinnedPost = p.pinnedPost,
            postsCount = p.postsCount,
            viewer = new_v,
        )
        _rebuild_profile_pane!(m; reset_scroll = false)
    end
    # Also refresh matching author viewer state on cached feed entries
    changed = false
    for (i, entry) in enumerate(m.feed_entries)
        a = entry.post.author
        a.did == target_did || continue
        ov = a.viewer
        new_flw = follow_uri === :unchanged ? (isnothing(ov) ? nothing : ov.following) : follow_uri
        new_mut = muted === :unchanged ? (isnothing(ov) ? nothing : ov.muted) : muted
        new_v = API.AppBskyActorDefsViewerState(
            blockedBy = isnothing(ov) ? nothing : ov.blockedBy,
            blocking = isnothing(ov) ? nothing : ov.blocking,
            blockingByList = isnothing(ov) ? nothing : ov.blockingByList,
            followedBy = isnothing(ov) ? nothing : ov.followedBy,
            following = new_flw,
            knownFollowers = isnothing(ov) ? nothing : ov.knownFollowers,
            muted = new_mut,
            mutedByList = isnothing(ov) ? nothing : ov.mutedByList,
        )
        new_a = API.AppBskyActorDefsProfileViewBasic(
            did = a.did,
            handle = a.handle,
            associated = a.associated,
            avatar = a.avatar,
            createdAt = a.createdAt,
            displayName = a.displayName,
            labels = a.labels,
            viewer = new_v,
        )
        p = entry.post
        new_p = API.AppBskyFeedDefsPostView(
            author = new_a,
            cid = p.cid,
            indexedAt = p.indexedAt,
            record = p.record,
            uri = p.uri,
            embed = p.embed,
            labels = p.labels,
            likeCount = p.likeCount,
            quoteCount = p.quoteCount,
            replyCount = p.replyCount,
            repostCount = p.repostCount,
            threadgate = p.threadgate,
            viewer = p.viewer,
        )
        m.feed_entries[i] = FeedEntry(new_p, entry.reposted_by, entry.is_pinned, entry.reply_parent_handle)
        changed = true
    end
    changed && _rebuild_detail_pane!(m; reset_scroll = false)
    nothing
end

function update!(m::BlueskyModel, evt::TaskEvent)
    val = evt.value
    if evt.id === :tick_1s
        m.sec_ticks += 1
        push!(m.firehose_rate_history, Float64(m.firehose_sec_count))
        while length(m.firehose_rate_history) > RATE_HISTORY_LEN
            popfirst!(m.firehose_rate_history)
        end
        m.firehose_sec_count = 0
        # Background unread notifications poll every 45s when signed in
        if m.auto_fetch && is_authenticated(m.agent) && (m.sec_ticks % 45 == 0)
            _fetch_unread_count!(m)
        end
        return nothing
    elseif evt.id === :jetstream_batch
        if val isa NamedTuple
            _ingest_jetstream_batch!(m, val.items, val.cursor)
        end
        return nothing
    elseif evt.id === :jetstream_error
        m.firehose_running = false
        _notify!(m, "Jetstream error: $(_format_err(val))", :error)
        return nothing
    elseif evt.id === :jetstream_stopped
        m.firehose_running = false
        return nothing
    elseif evt.id === :unread_count_loaded
        if val isa Integer
            m.notifs_unread = Int(val)
            _update_tab_labels!(m)
        end
        return nothing
    end

    if val isa Exception
        _notify!(m, "Error: $(_format_err(val))", :error)
        return nothing
    end

    if evt.id === :feed_loaded
        val.req_id == m.feed_req_id || return nothing
        if val.append
            append!(m.feed_entries, val.entries)
        else
            m.feed_entries = val.entries
            m.feed_list.selected = 1
            m.feed_list.offset = 0
            m.feed_card_offset = 0
        end
        if m.feed_mode === :bookmarks
            for e in val.entries
                push!(m.bookmarked_uris, string(e.post.uri))
            end
        end
        m.feed_cursor = val.cursor
        _rebuild_feed_list!(m)
        _rebuild_detail_pane!(m; reset_scroll = !val.append)
        val.silent || _notify!(m, "Loaded $(length(val.entries)) posts ($(val.label))", :success)

    elseif evt.id === :saved_feeds_loaded
        val.req_id == m.saved_feeds_req_id || return nothing
        m.saved_feeds = val.choices
        _rebuild_saved_feeds_list!(m)
        m.modal = :feeds
        _notify!(m, "Loaded $(length(val.choices)) feed sources", :success)

    elseif evt.id === :thread_loaded
        val.req_id == m.thread_req_id || return nothing
        m.thread_root = val.thread
        _rebuild_thread_pane!(m; reset_scroll = true)
        val.silent || _notify!(m, "Loaded thread ($(length(m.thread_posts)) posts)", :success)

    elseif evt.id === :profile_loaded
        val.req_id == m.profile_req_id || return nothing
        m.profile_data = val.profile
        m.profile_identity = val.identity
        _rebuild_profile_pane!(m; reset_scroll = true)
        badge = !isnothing(val.identity) && val.identity.handle_verified ? "verified" : "loaded"
        val.silent || _notify!(m, "Profile @$(val.profile.handle) ($badge)", :success)

    elseif evt.id === :notifs_loaded
        val.req_id == m.notifs_req_id || return nothing
        if val.append
            append!(m.notifs, val.notifications)
        else
            m.notifs = val.notifications
            m.notifs_list.selected = 1
        end
        m.notifs_cursor = val.cursor
        m.notifs_unread = val.unread
        _update_tab_labels!(m)
        _rebuild_notifs_pane!(m; reset_scroll = !val.append)
        val.silent || _notify!(m, "Loaded $(length(val.notifications)) notifications ($(val.unread) unread)", :success)

    elseif evt.id === :notifs_seen_done
        m.notifs_unread = 0
        m.notifs = [
            API.AppBskyNotificationListNotificationsNotification(
                author = n.author, cid = n.cid, indexedAt = n.indexedAt,
                isRead = true, reason = n.reason, record = n.record, uri = n.uri,
                labels = n.labels, reasonSubject = n.reasonSubject,
            ) for n in m.notifs
        ]
        _update_tab_labels!(m)
        _rebuild_notifs_pane!(m; reset_scroll = false)
        _notify!(m, "✓ All notifications marked seen", :success)

    elseif evt.id === :convos_loaded
        val.req_id == m.chat_convos_req_id || return nothing
        m.chat_convos = val.convos
        _rebuild_chat_panes!(m; reset_scroll = false)
        val.silent || _notify!(m, "Loaded $(length(val.convos)) chat conversations", :success)
        if !isempty(m.chat_convos) && isnothing(m.chat_active_convo_id)
            _fetch_convo_messages!(m, m.chat_convos[1].id; silent = true)
        end

    elseif evt.id === :convo_messages_loaded
        val.req_id == m.chat_msgs_req_id || return nothing
        m.chat_messages = val.messages
        # Clear local unread count for the opened convo
        for (i, c) in enumerate(m.chat_convos)
            if c.id == val.convo_id && c.unreadCount > 0
                m.chat_convos[i] = API.ChatBskyConvoDefsConvoView(
                    id = c.id, members = c.members, muted = c.muted, rev = c.rev,
                    unreadCount = 0, lastMessage = c.lastMessage, status = c.status,
                )
            end
        end
        _rebuild_chat_panes!(m; reset_scroll = true)
        val.silent || _notify!(m, "Loaded $(length(val.messages)) messages", :success)

    elseif evt.id === :chat_sent
        if m.chat_active_convo_id == val.convo_id
            push!(m.chat_messages, val.message)
            _rebuild_chat_panes!(m; reset_scroll = true)
        end
        _notify!(m, "✓ DM sent", :success)

    elseif evt.id === :login_done
        m.agent = val.agent
        h = String(val.session.handle)
        m.feed_mode = :timeline
        m.feed_actor = h
        m.profile_actor = h
        _notify!(m, "Signed in as @$h (PDS: $(service_url(m.agent)))", :success)
        _fetch_feed!(m; append = false, silent = true)
        _fetch_profile!(m, h; silent = true)
        _fetch_unread_count!(m)

    elseif evt.id === :post_done
        kind = val.is_quote ? "Quote-post" : val.is_reply ? "Reply" : "Post"
        _notify!(m, "✓ $kind published! ($(val.uri))", :success)
        if m.tabs.active == TAB_THREAD && !isnothing(m.thread_uri)
            _fetch_thread!(m, m.thread_uri; silent = true)
        else
            _fetch_feed!(m; append = false, silent = true)
        end

    elseif evt.id === :like_done
        _update_post_viewer!(m, val.post_uri; like_uri = val.like_uri)
        _notify!(m, val.liked ? "♥ Liked post" : "Removed like", :success)

    elseif evt.id === :repost_done
        _update_post_viewer!(m, val.post_uri; repost_uri = val.repost_uri)
        _notify!(m, val.reposted ? "↻ Reposted" : "Removed repost", :success)

    elseif evt.id === :bookmark_done
        if val.bookmarked
            push!(m.bookmarked_uris, val.uri)
            _notify!(m, "⚑ Bookmarked post", :success)
        else
            delete!(m.bookmarked_uris, val.uri)
            _notify!(m, "Removed bookmark", :info)
        end
        _rebuild_detail_pane!(m; reset_scroll = false)

    elseif evt.id === :follow_done
        _update_actor_viewer!(m, val.did; follow_uri = val.follow_uri)
        _notify!(m, val.following ? "✓ Following @$(val.handle)" : "Unfollowed @$(val.handle)", :success)

    elseif evt.id === :mute_done
        _update_actor_viewer!(m, val.did; muted = val.muted)
        _notify!(m, val.muted ? "◌ Muted @$(val.handle)" : "Unmuted @$(val.handle)", :info)
    end
    nothing
end

function _nav_key(evt::KeyEvent)::KeyEvent
    if evt.key == :char && evt.char == 'j'
        return KeyEvent(:down)
    elseif evt.key == :char && evt.char == 'k'
        return KeyEvent(:up)
    end
    return evt
end

function _switch_tab!(m::BlueskyModel, new_tab::Int)
    m.tabs.active = clamp(new_tab, 1, 6)
    if new_tab == TAB_NOTIFS && isempty(m.notifs) && is_authenticated(m.agent)
        _fetch_notifications!(m; append = false)
    elseif new_tab == TAB_CHAT && isempty(m.chat_convos) && is_authenticated(m.agent)
        _fetch_convos!(m)
    end
    nothing
end

function update!(m::BlueskyModel, evt::KeyEvent)
    if evt.key == :ctrl_c
        m.quit = true
        return nothing
    end

    if m.modal !== :none
        _handle_modal_key!(m, evt)
        return nothing
    end

    if evt.key == :char
        ch = evt.char
        if ch == 'q'
            m.quit = true
            return nothing
        elseif ch == '?'
            m.modal = :help
            return nothing
        elseif ch == 'b'
            m.ambient_bg = !m.ambient_bg
            _notify!(m, m.ambient_bg ? "Ambient DotWave horizon: ON" : "Ambient DotWave horizon: OFF", :info)
            return nothing
        elseif ch == 'v'
            m.scanlines = !m.scanlines
            _notify!(m, m.scanlines ? "CRT raster scanlines: ON" : "CRT raster scanlines: OFF", :info)
            return nothing
        elseif ch == 'P'
            cur_name = lowercase(theme().name)
            idx = findfirst(p -> p.name == cur_name, PHOSPHOR_THEMES)
            next_p = PHOSPHOR_THEMES[isnothing(idx) ? 1 : mod1(idx + 1, length(PHOSPHOR_THEMES))]
            _apply_theme_by_name!(next_p.name)
            _retheme_all!(m)
            _notify!(m, "Phosphor: $(next_p.label) ($(next_p.name))", :accent)
            return nothing
        elseif ch == '1'
            _switch_tab!(m, TAB_FEED); return nothing
        elseif ch == '2'
            _switch_tab!(m, TAB_THREAD); return nothing
        elseif ch == '3'
            _switch_tab!(m, TAB_PROFILE); return nothing
        elseif ch == '4'
            _switch_tab!(m, TAB_NOTIFS); return nothing
        elseif ch == '5'
            _switch_tab!(m, TAB_CHAT); return nothing
        elseif ch == '6'
            _switch_tab!(m, TAB_FIREHOSE); return nothing
        elseif ch == 'g'
            set_text!(m.goto_input, "")
            m.goto_input.error_msg = ""
            m.goto_input.focused = true
            m.modal = :goto
            return nothing
        elseif ch == '/'
            prefill = m.tabs.active == TAB_FIREHOSE ? m.firehose_filter : m.feed_query
            m.search_input.label = m.tabs.active == TAB_FIREHOSE ? "Filter: " : "Search: "
            set_text!(m.search_input, prefill)
            m.search_input.focused = true
            m.modal = :search
            return nothing
        elseif ch == 's'
            _fetch_saved_feeds!(m)
            return nothing
        elseif ch == 'c'
            if m.tabs.active == TAB_CHAT
                if !is_authenticated(m.agent)
                    _notify!(m, "Sign in with [L] to send DMs", :warning)
                elseif isnothing(_selected_convo(m))
                    _notify!(m, "Select a conversation first", :warning)
                else
                    set_text!(m.chat_input, "")
                    m.chat_input.focused = true
                    m.modal = :chat_send
                end
            else
                _open_compose!(m)
            end
            return nothing
        elseif ch == 'L'
            m.login_field = 1
            m.login_handle_input.focused = true
            m.login_pass_input.focused = false
            set_text!(m.login_pass_input, "")
            m.modal = :login
            return nothing
        end
    end

    tab = m.tabs.active

    if tab == TAB_FEED
        if evt.key == :tab || evt.key == :backtab
            m.feed_focus = m.feed_focus === :list ? :detail : :list
            m.feed_list.focused = (m.feed_focus === :list)
        elseif evt.key == :left
            m.feed_focus = :list
            m.feed_list.focused = true
        elseif evt.key == :right
            m.feed_focus = :detail
            m.feed_list.focused = false
        elseif evt.key == :enter || (evt.key == :char && evt.char == 't')
            entry = _selected_entry(m)
            if !isnothing(entry)
                m.tabs.active = TAB_THREAD
                _fetch_thread!(m, entry.post.uri)
            end
        elseif evt.key == :char && evt.char == 'o'
            entry = _selected_entry(m)
            if !isnothing(entry)
                m.tabs.active = TAB_PROFILE
                _fetch_profile!(m, String(entry.post.author.handle))
            end
        elseif evt.key == :char && evt.char == 'r'
            _fetch_feed!(m; append = false)
        elseif evt.key == :char && evt.char == 'n'
            _fetch_feed!(m; append = true)
        elseif evt.key == :char && evt.char == 'T'
            if is_authenticated(m.agent)
                m.feed_mode = m.feed_mode === :timeline ? :author : :timeline
                _fetch_feed!(m; append = false)
            else
                _notify!(m, "Sign in with [L] to view your Home Timeline", :warning)
            end
        elseif evt.key == :char && evt.char == 'l'
            _toggle_like!(m)
        elseif evt.key == :char && evt.char == 'R'
            _toggle_repost!(m)
        elseif evt.key == :char && evt.char == 'B'
            _toggle_bookmark!(m)
        elseif evt.key == :char && evt.char == 'F'
            _toggle_follow!(m)
        elseif evt.key == :char && evt.char == 'M'
            _toggle_mute!(m)
        elseif evt.key == :char && evt.char == 'i'
            _open_gallery!(m)
        elseif evt.key == :char && evt.char == 'p'
            entry = _selected_entry(m)
            isnothing(entry) || _open_compose!(m; reply_to = entry.post)
        elseif evt.key == :char && evt.char == 'Q'
            entry = _selected_entry(m)
            isnothing(entry) || _open_compose!(m; quote_of = entry.post)
        else
            nev = _nav_key(evt)
            if m.feed_focus === :list
                old_sel = m.feed_list.selected
                if handle_key!(m.feed_list, nev) && m.feed_list.selected != old_sel
                    _rebuild_detail_pane!(m; reset_scroll = true)
                end
            else
                handle_key!(m.detail_pane, nev)
            end
        end

    elseif tab == TAB_THREAD
        if evt.key == :escape || evt.key == :backspace
            m.tabs.active = TAB_FEED
        elseif evt.key == :char && evt.char == 'r'
            isnothing(m.thread_uri) || _fetch_thread!(m, m.thread_uri)
        elseif evt.key == :char && evt.char == 'o'
            if m.thread_root isa API.AppBskyFeedDefsThreadViewPost
                m.tabs.active = TAB_PROFILE
                _fetch_profile!(m, String(m.thread_root.post.author.handle))
            end
        elseif evt.key == :char && evt.char == 'p'
            if m.thread_root isa API.AppBskyFeedDefsThreadViewPost
                _open_compose!(m; reply_to = m.thread_root.post)
            end
        elseif evt.key == :char && evt.char == 'Q'
            if m.thread_root isa API.AppBskyFeedDefsThreadViewPost
                _open_compose!(m; quote_of = m.thread_root.post)
            end
        elseif evt.key == :char && evt.char == 'i'
            _open_gallery!(m)
        else
            handle_key!(m.thread_pane, _nav_key(evt))
        end

    elseif tab == TAB_PROFILE
        if evt.key == :char && evt.char == 'f'
            actor = isnothing(m.profile_data) ? m.profile_actor : String(m.profile_data.handle)
            m.feed_mode = :author
            m.feed_actor = actor
            m.tabs.active = TAB_FEED
            _fetch_feed!(m; append = false)
        elseif evt.key == :char && evt.char == 'F'
            _toggle_follow!(m)
        elseif evt.key == :char && evt.char == 'M'
            _toggle_mute!(m)
        elseif evt.key == :char && evt.char == 'i'
            _open_gallery!(m)
        elseif evt.key == :char && evt.char == 'r'
            _fetch_profile!(m, m.profile_actor)
        else
            handle_key!(m.profile_pane, _nav_key(evt))
        end

    elseif tab == TAB_NOTIFS
        if evt.key == :char && evt.char == 'r'
            _fetch_notifications!(m; append = false)
        elseif evt.key == :char && evt.char == 'n'
            _fetch_notifications!(m; append = true)
        elseif evt.key == :char && evt.char == 'm'
            _mark_notifications_seen!(m)
        elseif evt.key == :char && evt.char == 'o'
            nf = _selected_notif(m)
            if !isnothing(nf)
                m.tabs.active = TAB_PROFILE
                _fetch_profile!(m, String(nf.author.handle))
            end
        elseif evt.key == :enter
            nf = _selected_notif(m)
            if !isnothing(nf)
                if nf.reason == "follow"
                    m.tabs.active = TAB_PROFILE
                    _fetch_profile!(m, String(nf.author.handle))
                else
                    target_uri = isnothing(nf.reasonSubject) ? nf.uri : nf.reasonSubject
                    m.tabs.active = TAB_THREAD
                    _fetch_thread!(m, target_uri)
                end
            end
        else
            old_sel = m.notifs_list.selected
            if handle_key!(m.notifs_list, _nav_key(evt)) && m.notifs_list.selected != old_sel
                _rebuild_notifs_pane!(m; reset_scroll = false)
            end
        end

    elseif tab == TAB_CHAT
        if evt.key == :tab || evt.key == :backtab
            m.chat_focus = m.chat_focus === :convos ? :messages : :convos
        elseif evt.key == :left
            m.chat_focus = :convos
        elseif evt.key == :right
            m.chat_focus = :messages
        elseif evt.key == :char && evt.char == 'r'
            _fetch_convos!(m)
            !isnothing(m.chat_active_convo_id) && _fetch_convo_messages!(m, m.chat_active_convo_id; silent = true)
        elseif evt.key == :enter
            convo = _selected_convo(m)
            if !isnothing(convo)
                if m.chat_focus === :convos
                    _fetch_convo_messages!(m, convo.id)
                else
                    set_text!(m.chat_input, "")
                    m.chat_input.focused = true
                    m.modal = :chat_send
                end
            end
        else
            nev = _nav_key(evt)
            if m.chat_focus === :convos
                old_sel = m.chat_convos_list.selected
                if handle_key!(m.chat_convos_list, nev) && m.chat_convos_list.selected != old_sel
                    convo = _selected_convo(m)
                    isnothing(convo) || _fetch_convo_messages!(m, convo.id; silent = true)
                end
            else
                handle_key!(m.chat_messages_pane, nev)
            end
        end

    elseif tab == TAB_FIREHOSE
        if evt.key == :char && evt.char == ' '
            if m.firehose_running
                _stop_firehose!(m)
                _notify!(m, "Jetstream standby (press Space to reconnect)", :warning)
            else
                _start_firehose!(m)
            end
        elseif evt.key == :char && evt.char == 'C'
            m.firehose_preset_idx = mod1(m.firehose_preset_idx + 1, length(JETSTREAM_PRESETS))
            preset = JETSTREAM_PRESETS[m.firehose_preset_idx]
            if m.firehose_running
                _stop_firehose!(m)
                _start_firehose!(m)
            else
                _notify!(m, "Jetstream preset: $(preset.label)", :info)
            end
        elseif evt.key == :char && evt.char == 'x'
            empty!(m.firehose_items)
            m.firehose_total = 0
            m.firehose_matched = 0
            m.firehose_posts = 0
            m.firehose_likes = 0
            m.firehose_reposts = 0
            fill!(m.firehose_rate_history, 0.0)
            _rebuild_firehose_pane!(m)
            _notify!(m, "Cleared firehose buffer", :info)
        else
            handle_key!(m.firehose_pane, _nav_key(evt))
        end
    end
    nothing
end

function update!(m::BlueskyModel, evt::MouseEvent)
    m.modal !== :none && return nothing

    if handle_mouse!(m.tabs, evt) === :changed
        _switch_tab!(m, m.tabs.active)
        return nothing
    end

    tab = m.tabs.active
    if tab == TAB_FEED
        if handle_resize!(m.feed_split, evt)
            return nothing
        end
        if Base.contains(m.rect_feed_list, evt.x, evt.y)
            if evt.button == mouse_left && evt.action == mouse_press
                m.feed_focus = :list
                m.feed_list.focused = true
                hit = feed_card_hit_index(m.rect_feed_cards_inner, m.feed_card_offset, length(m.feed_entries), evt.x, evt.y)
                if hit > 0 && hit != m.feed_list.selected
                    m.feed_list.selected = hit
                    _rebuild_detail_pane!(m; reset_scroll = true)
                end
            elseif evt.button == mouse_scroll_up && !isempty(m.feed_entries)
                old_sel = m.feed_list.selected
                m.feed_list.selected = max(1, old_sel - 1)
                m.feed_list.selected != old_sel && _rebuild_detail_pane!(m; reset_scroll = true)
            elseif evt.button == mouse_scroll_down && !isempty(m.feed_entries)
                old_sel = m.feed_list.selected
                m.feed_list.selected = min(length(m.feed_entries), old_sel + 1)
                m.feed_list.selected != old_sel && _rebuild_detail_pane!(m; reset_scroll = true)
            end
        elseif Base.contains(m.rect_feed_detail, evt.x, evt.y)
            if evt.button == mouse_left && evt.action == mouse_press
                m.feed_focus = :detail
                m.feed_list.focused = false
            end
            handle_mouse!(m.detail_pane, evt)
        end
    elseif tab == TAB_THREAD
        handle_mouse!(m.thread_pane, evt)
    elseif tab == TAB_PROFILE
        handle_mouse!(m.profile_pane, evt)
    elseif tab == TAB_NOTIFS
        handle_mouse!(m.notifs_pane, evt)
    elseif tab == TAB_CHAT
        if handle_resize!(m.chat_split, evt)
            return nothing
        end
        if Base.contains(m.rect_chat_convos, evt.x, evt.y)
            if evt.button == mouse_left && evt.action == mouse_press
                m.chat_focus = :convos
            end
        elseif Base.contains(m.rect_chat_messages, evt.x, evt.y)
            if evt.button == mouse_left && evt.action == mouse_press
                m.chat_focus = :messages
            end
            handle_mouse!(m.chat_messages_pane, evt)
        end
    elseif tab == TAB_FIREHOSE
        handle_mouse!(m.firehose_pane, evt)
    end
    nothing
end

function view(m::BlueskyModel, f::Frame)
    m.tick += 1
    if m.status_ttl > 0
        m.status_ttl -= 1
    end
    if m.last_theme_name != theme().name
        _retheme_all!(m)
    end

    buf = f.buffer
    area = f.area

    _fill_surface!(buf, area, _canvas_bg_rgb())
    if m.ambient_bg && area.width >= 40 && area.height >= 14
        render_background!(
            m.dotwave, buf, area, m.tick;
            brightness = light_mode() ? 0.14 : 0.22,
            saturation = 0.45,
            speed = 0.35,
        )
    end

    tab_h = area.height >= 16 ? 3 : 1
    rows = split_layout(Layout(Vertical, [Fixed(1), Fixed(tab_h), Fill(1), Fixed(1)]), area)
    _render_deck_header!(m, rows[1], buf)
    _render_tab_strip!(m, rows[2], buf)

    body_area = area.width >= 88 ? margin(rows[3]; left = 1, right = 1) : rows[3]

    tab = m.tabs.active
    if tab == TAB_FEED
        _render_feed_tab!(m, body_area, buf)
    elseif tab == TAB_THREAD
        _render_thread_tab!(m, body_area, buf)
    elseif tab == TAB_PROFILE
        _render_profile_tab!(m, body_area, buf)
    elseif tab == TAB_NOTIFS
        _render_notifs_tab!(m, body_area, buf)
    elseif tab == TAB_CHAT
        _render_chat_tab!(m, body_area, buf)
    else
        _render_firehose_tab!(m, body_area, buf)
    end

    _render_status_bar!(m, rows[4], buf)

    if m.modal !== :none
        _render_modal!(m, area, buf)
    end
    nothing
end
