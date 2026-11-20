# actions.jl — Async ATProto.jl data fetchers, social/bookmark/chat mutations, gallery extraction & Jetstream worker.

function _extract_images_from_embed(embed)::Vector{GalleryImage}
    imgs = GalleryImage[]
    if embed isa API.AppBskyEmbedImagesView
        for (i, im) in enumerate(embed.images)
            dims = isnothing(im.aspectRatio) ? "auto" : "$(im.aspectRatio.width)×$(im.aspectRatio.height)"
            push!(imgs, GalleryImage("Image $i", im.alt, im.fullsize, im.thumb, dims))
        end
    elseif embed isa API.AppBskyEmbedRecordWithMediaView
        append!(imgs, _extract_images_from_embed(embed.media))
    elseif embed isa API.AppBskyEmbedExternalView && !isnothing(embed.external.thumb)
        ext = embed.external
        push!(imgs, GalleryImage("Link Thumbnail", "$(ext.title) — $(ext.description)", ext.thumb, ext.thumb, "card"))
    elseif embed isa API.AppBskyEmbedVideoView && !isnothing(embed.thumbnail)
        dims = isnothing(embed.aspectRatio) ? "video" : "$(embed.aspectRatio.width)×$(embed.aspectRatio.height)"
        push!(imgs, GalleryImage("Video Poster", something(embed.alt, "(no video alt text)"), embed.thumbnail, embed.thumbnail, dims))
    end
    return imgs
end

function _open_gallery!(m::BlueskyModel)
    imgs = GalleryImage[]
    title = "Media & Alt-Text Inspector"
    if m.tabs.active == TAB_PROFILE && !isnothing(m.profile_data)
        p = m.profile_data
        title = "@$(p.handle) Profile Media"
        if !isnothing(p.avatar) && !isempty(p.avatar)
            push!(imgs, GalleryImage("Avatar", "Profile avatar for @$(p.handle)", p.avatar, p.avatar, "avatar"))
        end
        if !isnothing(p.banner) && !isempty(p.banner)
            push!(imgs, GalleryImage("Banner", "Profile banner for @$(p.handle)", p.banner, p.banner, "banner"))
        end
    elseif m.tabs.active == TAB_THREAD && m.thread_root isa API.AppBskyFeedDefsThreadViewPost
        post = m.thread_root.post
        title = "@$(post.author.handle) Thread Media"
        imgs = _extract_images_from_embed(post.embed)
    else
        entry = _selected_entry(m)
        if !isnothing(entry)
            title = "@$(entry.post.author.handle) Post Media"
            imgs = _extract_images_from_embed(entry.post.embed)
        end
    end

    if isempty(imgs)
        _notify!(m, "No images or media attachments on the selected item", :warning)
        return
    end
    m.gallery_images = imgs
    m.gallery_idx = 1
    m.gallery_title = title
    m.modal = :gallery
    nothing
end

function _fetch_feed!(m::BlueskyModel; append::Bool = false, silent::Bool = false)
    m.feed_req_id += 1
    req_id = m.feed_req_id
    mode = m.feed_mode
    actor = m.feed_actor
    query = m.feed_query
    src_uri = m.feed_source_uri
    src_label = m.feed_source_label
    cursor = append ? m.feed_cursor : nothing
    agent = m.agent

    if append && isnothing(cursor)
        silent || _notify!(m, "Reached end of feed", :warning)
        return
    end

    label = if mode === :timeline
        "timeline"
    elseif mode === :search
        "search $(repr(query))"
    elseif mode === :bookmarks
        "bookmarks"
    elseif mode === :saved_feed || mode === :list_feed
        isempty(src_label) ? src_uri : src_label
    else
        "@$actor"
    end
    silent || _notify!(m, append ? "Loading more ($label)…" : "Loading $label…", :info)

    spawn_task!(m.queue, :feed_loaded) do
        if mode === :timeline
            out = get_timeline(agent; limit = 25, cursor = cursor)
            entries = [FeedEntry(item) for item in out.feed]
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = out.cursor, label = label)
        elseif mode === :search
            out = xrpc(agent, API.App.Bsky.Feed.SearchPosts; q = query, limit = 25, cursor = cursor)
            entries = [FeedEntry(p) for p in out.posts]
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = out.cursor, label = label)
        elseif mode === :saved_feed
            out = xrpc(agent, API.App.Bsky.Feed.GetFeed; feed = convert(AtUri, src_uri), limit = 25, cursor = cursor)
            entries = [FeedEntry(item) for item in out.feed]
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = out.cursor, label = label)
        elseif mode === :list_feed
            out = xrpc(agent, API.App.Bsky.Feed.GetListFeed; list = convert(AtUri, src_uri), limit = 25, cursor = cursor)
            entries = [FeedEntry(item) for item in out.feed]
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = out.cursor, label = label)
        elseif mode === :bookmarks
            raw = get_bookmarks(agent; limit = 25, cursor = cursor)
            bms = get(raw, "bookmarks", Any[])
            next_cur = get(raw, "cursor", nothing)
            uris = AtUri[]
            direct_entries = FeedEntry[]
            for bm in bms
                bm isa AbstractDict || continue
                item = get(bm, "item", nothing)
                if item isa AbstractDict && haskey(item, "uri") && haskey(item, "author")
                    p = JSON.parse(JSON.json(item), API.AppBskyFeedDefsPostView)
                    push!(direct_entries, FeedEntry(p))
                else
                    subj = get(bm, "subject", nothing)
                    if subj isa AbstractDict && haskey(subj, "uri")
                        u = tryparse(AtUri, String(subj["uri"]))
                        isnothing(u) || push!(uris, u)
                    end
                end
            end
            entries = if !isempty(direct_entries)
                direct_entries
            elseif !isempty(uris)
                out = xrpc(agent, API.App.Bsky.Feed.GetPosts; uris = uris)
                [FeedEntry(p) for p in out.posts]
            else
                FeedEntry[]
            end
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = next_cur, label = label)
        else
            out = get_author_feed(agent, actor; limit = 25, cursor = cursor)
            entries = [FeedEntry(item) for item in out.feed]
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = out.cursor, label = label)
        end
    end
    nothing
end

function _fetch_saved_feeds!(m::BlueskyModel)
    m.saved_feeds_req_id += 1
    req_id = m.saved_feeds_req_id
    agent = m.agent
    cur_actor = m.feed_actor

    if !is_authenticated(agent)
        m.saved_feeds = SavedFeedChoice[
            SavedFeedChoice("◈ @$(cur_actor) Author Feed", :author, cur_actor, true),
            SavedFeedChoice("◈ @bsky.app Official", :author, "bsky.app", false),
        ]
        _rebuild_saved_feeds_list!(m)
        m.modal = :feeds
        _notify!(m, "Sign in with [L] to load personal Saved Feeds, Lists & Bookmarks", :warning)
        return
    end

    _notify!(m, "Loading Saved Feeds, Lists & Bookmarks…", :info)
    spawn_task!(m.queue, :saved_feeds_loaded) do
        choices = SavedFeedChoice[
            SavedFeedChoice("★ Home Timeline (Following)", :timeline, "following", true),
            SavedFeedChoice("⚑ Private Bookmarks", :bookmarks, "bookmarks", true),
        ]
        saved = try
            get_saved_feeds(agent)
        catch
            API.AppBskyActorDefsSavedFeed[]
        end

        feed_uris = AtUri[]
        for sf in saved
            if sf.type == "feed"
                u = tryparse(AtUri, sf.value)
                isnothing(u) || push!(feed_uris, u)
            end
        end
        feed_names = Dict{String, String}()
        if !isempty(feed_uris)
            try
                gens = xrpc(agent, API.App.Bsky.Feed.GetFeedGenerators; feeds = feed_uris)
                for g in gens.feeds
                    feed_names[string(g.uri)] = g.displayName
                end
            catch
            end
        end

        for sf in saved
            sf.type == "timeline" && continue
            if sf.type == "feed"
                nm = get(feed_names, sf.value, sf.value)
                push!(choices, SavedFeedChoice("◈ Feed: $nm", :feed, sf.value, sf.pinned))
            elseif sf.type == "list"
                push!(choices, SavedFeedChoice("▤ List: $(sf.value)", :list, sf.value, sf.pinned))
            end
        end

        # Also include user's own lists if not already in saved feeds
        sess = session(agent)
        if !isnothing(sess)
            seen = Set(c.value for c in choices)
            try
                lists_out = xrpc(agent, API.App.Bsky.Graph.GetLists; actor = String(sess.did), limit = 25)
                for lst in lists_out.lists
                    us = string(lst.uri)
                    us in seen && continue
                    push!(choices, SavedFeedChoice("▤ List: $(lst.name)", :list, us, false))
                end
            catch
            end
        end

        return (req_id = req_id, choices = choices)
    end
    nothing
end

function _fetch_thread!(m::BlueskyModel, uri::AtUri; silent::Bool = false)
    m.thread_req_id += 1
    req_id = m.thread_req_id
    m.thread_uri = uri
    agent = m.agent
    silent || _notify!(m, "Loading thread…", :info)

    spawn_task!(m.queue, :thread_loaded) do
        out = get_post_thread(agent, uri; depth = 6, parentHeight = 10)
        return (req_id = req_id, silent = silent, uri = uri, thread = out.thread)
    end
    nothing
end

function _fetch_profile!(m::BlueskyModel, actor::AbstractString; silent::Bool = false)
    m.profile_req_id += 1
    req_id = m.profile_req_id
    m.profile_actor = String(actor)
    m.profile_identity = nothing
    agent = m.agent
    resolver = m.identity_resolver
    silent || _notify!(m, "Loading profile @$actor…", :info)

    spawn_task!(m.queue, :profile_loaded) do
        prof = get_profile(agent, actor)
        id_info = try
            resolver(prof.did)
        catch
            nothing
        end
        return (req_id = req_id, silent = silent, profile = prof, identity = id_info)
    end
    nothing
end

function _fetch_notifications!(m::BlueskyModel; append::Bool = false, silent::Bool = false)
    if !is_authenticated(m.agent)
        silent || _notify!(m, "Sign in with [L] to load notifications", :warning)
        return
    end
    m.notifs_req_id += 1
    req_id = m.notifs_req_id
    cursor = append ? m.notifs_cursor : nothing
    if append && isnothing(cursor)
        silent || _notify!(m, "No older notifications", :warning)
        return
    end
    agent = m.agent
    silent || _notify!(m, append ? "Loading older notifications…" : "Loading notifications…", :info)

    spawn_task!(m.queue, :notifs_loaded) do
        out = get_notifications(agent; limit = 30, cursor = cursor)
        unread = try
            get_unread_count(agent)
        catch
            count(n -> !n.isRead, out.notifications)
        end
        return (req_id = req_id, append = append, silent = silent,
                notifications = out.notifications, cursor = out.cursor, unread = unread)
    end
    nothing
end

function _fetch_unread_count!(m::BlueskyModel)
    is_authenticated(m.agent) || return
    agent = m.agent
    spawn_task!(m.queue, :unread_count_loaded) do
        return get_unread_count(agent)
    end
    nothing
end

function _mark_notifications_seen!(m::BlueskyModel)
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to update notifications", :warning)
        return
    end
    agent = m.agent
    _notify!(m, "Marking notifications seen…", :info)
    spawn_task!(m.queue, :notifs_seen_done) do
        update_seen_notifications!(agent)
        return true
    end
    nothing
end

function _fetch_convos!(m::BlueskyModel; silent::Bool = false)
    if !is_authenticated(m.agent)
        silent || _notify!(m, "Sign in with [L] to load Chat DMs", :warning)
        return
    end
    m.chat_convos_req_id += 1
    req_id = m.chat_convos_req_id
    agent = m.agent
    silent || _notify!(m, "Loading Chat conversations…", :info)

    spawn_task!(m.queue, :convos_loaded) do
        out = list_convos(agent; limit = 30)
        return (req_id = req_id, silent = silent, convos = out.convos)
    end
    nothing
end

function _fetch_convo_messages!(m::BlueskyModel, convo_id::AbstractString; silent::Bool = false)
    if !is_authenticated(m.agent)
        silent || _notify!(m, "Sign in with [L] to read Chat DMs", :warning)
        return
    end
    m.chat_msgs_req_id += 1
    req_id = m.chat_msgs_req_id
    cid = String(convo_id)
    m.chat_active_convo_id = cid
    agent = m.agent
    silent || _notify!(m, "Loading messages…", :info)

    spawn_task!(m.queue, :convo_messages_loaded) do
        out = get_convo_messages(agent, cid; limit = 40)
        # API returns newest-first; reverse for chronological reading
        msgs = reverse(collect(Any, out.messages))
        try
            update_convo_read!(agent, cid)
        catch
        end
        return (req_id = req_id, silent = silent, convo_id = cid, messages = msgs)
    end
    nothing
end

function _send_chat_message!(m::BlueskyModel, msg_text::AbstractString)
    txt = strip(String(msg_text))
    isempty(txt) && return
    convo = _selected_convo(m)
    if isnothing(convo)
        _notify!(m, "Select a conversation first", :warning)
        return
    end
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to send DMs", :warning)
        return
    end
    cid = convo.id
    agent = m.agent
    _notify!(m, "Sending DM…", :info)
    spawn_task!(m.queue, :chat_sent) do
        rt = richtext(agent, txt)
        sent = send_chat_message!(agent, cid, rt)
        return (convo_id = cid, message = sent)
    end
    nothing
end

function _start_login!(m::BlueskyModel, handle::AbstractString, password::AbstractString)
    h = strip(String(handle))
    h = startswith(h, "@") ? h[2:end] : h
    pw = strip(String(password))
    if isempty(h) || isempty(pw)
        _notify!(m, "Handle and app password are required", :error)
        return
    end
    _notify!(m, "Signing in as @$h…", :info)
    spawn_task!(m.queue, :login_done) do
        agent = AtpAgent()
        sess = login!(agent, h, pw)
        return (agent = agent, session = sess)
    end
    nothing
end

function _submit_compose!(m::BlueskyModel)
    txt = strip(text(m.compose_area))
    if isempty(txt)
        _notify!(m, "Post cannot be empty", :warning)
        return
    end
    g_len = grapheme_length(txt)
    b_len = byte_length(txt)
    if g_len > 300 || b_len > 3000
        _notify!(m, "Post too long ($g_len/300 gr, $b_len/3000 B)", :error)
        return
    end

    reply_post = m.compose_reply_to
    quote_post = m.compose_quote_of
    agent = m.agent
    m.modal = :none
    m.compose_reply_to = nothing
    m.compose_quote_of = nothing

    if !is_authenticated(agent)
        n_m = length(detect_mentions(txt))
        n_l = length(detect_links(txt))
        n_t = length(detect_tags(txt))
        prefix = !isnothing(quote_post) ? "Dry-run Quote OK" : !isnothing(reply_post) ? "Dry-run Reply OK" : "Dry-run Post OK"
        _notify!(m, "$prefix ($g_len gr, $(n_m)m/$(n_l)l/$(n_t)t) — press L to log in & publish", :warning; ttl = 360)
        return
    end

    label = !isnothing(quote_post) ? "Publishing quote-post…" : !isnothing(reply_post) ? "Publishing reply…" : "Publishing post…"
    _notify!(m, label, :info)
    spawn_task!(m.queue, :post_done) do
        rt = richtext(agent, txt)
        out = if !isnothing(quote_post)
            quote_post!(agent, quote_post, rt; langs = ["en"])
        elseif !isnothing(reply_post)
            reply!(agent, reply_post, rt; langs = ["en"])
        else
            post!(agent, rt; langs = ["en"])
        end
        return (uri = out.uri, is_reply = !isnothing(reply_post), is_quote = !isnothing(quote_post))
    end
    nothing
end

function _toggle_like!(m::BlueskyModel)
    entry = _selected_entry(m)
    isnothing(entry) && return
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to like posts", :warning)
        return
    end
    post = entry.post
    agent = m.agent
    existing = !isnothing(post.viewer) ? post.viewer.like : nothing
    _notify!(m, isnothing(existing) ? "Liking post…" : "Removing like…", :info)

    spawn_task!(m.queue, :like_done) do
        if isnothing(existing)
            out = like!(agent, post)
            return (post_uri = post.uri, like_uri = out.uri, liked = true)
        else
            unlike!(agent, existing)
            return (post_uri = post.uri, like_uri = nothing, liked = false)
        end
    end
    nothing
end

function _toggle_repost!(m::BlueskyModel)
    entry = _selected_entry(m)
    isnothing(entry) && return
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to repost", :warning)
        return
    end
    post = entry.post
    agent = m.agent
    existing = !isnothing(post.viewer) ? post.viewer.repost : nothing
    _notify!(m, isnothing(existing) ? "Reposting…" : "Removing repost…", :info)

    spawn_task!(m.queue, :repost_done) do
        if isnothing(existing)
            out = repost!(agent, post)
            return (post_uri = post.uri, repost_uri = out.uri, reposted = true)
        else
            unrepost!(agent, existing)
            return (post_uri = post.uri, repost_uri = nothing, reposted = false)
        end
    end
    nothing
end

function _toggle_bookmark!(m::BlueskyModel)
    entry = _selected_entry(m)
    isnothing(entry) && return
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to bookmark posts", :warning)
        return
    end
    post = entry.post
    uri_str = string(post.uri)
    was_bm = uri_str in m.bookmarked_uris
    agent = m.agent
    _notify!(m, was_bm ? "Removing bookmark…" : "Bookmarking post…", :info)

    spawn_task!(m.queue, :bookmark_done) do
        if was_bm
            delete_bookmark!(agent, post.uri)
            return (uri = uri_str, bookmarked = false)
        else
            create_bookmark!(agent, post)
            return (uri = uri_str, bookmarked = true)
        end
    end
    nothing
end

function _toggle_follow!(m::BlueskyModel)
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to follow accounts", :warning)
        return
    end
    target_did, target_handle, existing = if m.tabs.active == TAB_PROFILE && !isnothing(m.profile_data)
        p = m.profile_data
        (p.did, String(p.handle), !isnothing(p.viewer) ? p.viewer.following : nothing)
    else
        entry = _selected_entry(m)
        isnothing(entry) && return
        a = entry.post.author
        (a.did, String(a.handle), !isnothing(a.viewer) ? a.viewer.following : nothing)
    end
    agent = m.agent
    _notify!(m, isnothing(existing) ? "Following @$target_handle…" : "Unfollowing @$target_handle…", :info)

    spawn_task!(m.queue, :follow_done) do
        if isnothing(existing)
            out = follow!(agent, target_did)
            return (did = target_did, handle = target_handle, follow_uri = out.uri, following = true)
        else
            unfollow!(agent, existing)
            return (did = target_did, handle = target_handle, follow_uri = nothing, following = false)
        end
    end
    nothing
end

function _toggle_mute!(m::BlueskyModel)
    if !is_authenticated(m.agent)
        _notify!(m, "Sign in with [L] to mute accounts", :warning)
        return
    end
    target_did, target_handle, was_muted = if m.tabs.active == TAB_PROFILE && !isnothing(m.profile_data)
        p = m.profile_data
        (p.did, String(p.handle), !isnothing(p.viewer) && something(p.viewer.muted, false))
    else
        entry = _selected_entry(m)
        isnothing(entry) && return
        a = entry.post.author
        (a.did, String(a.handle), !isnothing(a.viewer) && something(a.viewer.muted, false))
    end
    agent = m.agent
    _notify!(m, was_muted ? "Unmuting @$target_handle…" : "Muting @$target_handle…", :info)

    spawn_task!(m.queue, :mute_done) do
        if was_muted
            unmute!(agent, target_did)
            return (did = target_did, handle = target_handle, muted = false)
        else
            mute!(agent, target_did)
            return (did = target_did, handle = target_handle, muted = true)
        end
    end
    nothing
end

# ── Jetstream Firehose Worker ───────────────────────────────────────

function _push_queue!(q::TaskQueue, evt::Event)
    try
        put!(q.channel, evt)
        q.on_ready !== nothing && q.on_ready()
    catch
    end
    nothing
end

function _event_to_jetstream_item(ev)::Union{JetstreamItem, Nothing}
    if ev isa JetstreamCommitEvent
        col = string(ev.collection)
        if ev.record isa API.AppBskyFeedPost && ev.operation === :create
            return JetstreamItem(:post, string(ev.did), col, ev.operation, ev.record.text, ev.record.facets, ev.time_us)
        elseif col == "app.bsky.feed.like"
            return JetstreamItem(:like, string(ev.did), col, ev.operation, "", nothing, ev.time_us)
        elseif col == "app.bsky.feed.repost"
            return JetstreamItem(:repost, string(ev.did), col, ev.operation, "", nothing, ev.time_us)
        else
            return JetstreamItem(:other, string(ev.did), col, ev.operation, "", nothing, ev.time_us)
        end
    end
    return nothing
end

function _start_firehose!(m::BlueskyModel)
    m.firehose_running && return
    token = CancelToken()
    m.jetstream_cancel = token
    m.firehose_running = true
    preset = JETSTREAM_PRESETS[m.firehose_preset_idx]
    connector = m.jetstream_connector
    q = m.queue
    stream_ref = m.jetstream_stream
    _notify!(m, "Tuning into Jetstream ($(preset.label))…", :info)
    _rebuild_firehose_pane!(m)

    Threads.@spawn begin
        stream = nothing
        try
            stream = connector(copy(preset.collections))
            stream_ref[] = stream
            batch = JetstreamItem[]
            last_flush = time()
            for ev in stream
                is_cancelled(token) && break
                item = _event_to_jetstream_item(ev)
                if !isnothing(item)
                    push!(batch, item)
                end
                now_t = time()
                if length(batch) >= 12 || (now_t - last_flush >= 0.12 && !isempty(batch))
                    _push_queue!(q, TaskEvent(:jetstream_batch, (items = copy(batch), cursor = last_cursor(stream))))
                    empty!(batch)
                    last_flush = now_t
                end
            end
            if !isempty(batch) && !is_cancelled(token)
                _push_queue!(q, TaskEvent(:jetstream_batch, (items = batch, cursor = last_cursor(stream))))
            end
        catch e
            is_cancelled(token) || _push_queue!(q, TaskEvent(:jetstream_error, e))
        finally
            if stream !== nothing
                try close(stream) catch end
            end
            if stream_ref[] === stream
                stream_ref[] = nothing
            end
            _push_queue!(q, TaskEvent(:jetstream_stopped, nothing))
        end
    end
    nothing
end

function _stop_firehose!(m::BlueskyModel)
    if m.jetstream_cancel !== nothing
        cancel!(m.jetstream_cancel)
        m.jetstream_cancel = nothing
    end
    st = m.jetstream_stream[]
    if st !== nothing
        m.jetstream_stream[] = nothing
        try close(st) catch end
    end
    m.firehose_running = false
    nothing
end

function _ingest_jetstream_batch!(m::BlueskyModel, items::Vector{JetstreamItem}, cursor::Union{Int64, Nothing})
    isnothing(cursor) || (m.firehose_cursor = cursor)
    kw = lowercase(strip(m.firehose_filter))
    had_empty = isempty(m.firehose_items)
    added = Vector{Span}[]

    for item in items
        m.firehose_total += 1
        m.firehose_sec_count += 1
        if item.kind === :post
            m.firehose_posts += 1
        elseif item.kind === :like
            m.firehose_likes += 1
        elseif item.kind === :repost
            m.firehose_reposts += 1
        end

        matches = if isempty(kw)
            true
        elseif item.kind === :post
            occursin(kw, lowercase(item.text)) || occursin(kw, lowercase(item.did))
        else
            occursin(kw, lowercase(item.collection)) || occursin(kw, lowercase(item.did))
        end

        if matches
            m.firehose_matched += 1
            push!(m.firehose_items, item)
            push!(added, _format_jetstream_line(item))
        end
    end

    if length(m.firehose_items) > MAX_FIREHOSE_LINES
        excess = length(m.firehose_items) - MAX_FIREHOSE_LINES
        deleteat!(m.firehose_items, 1:excess)
        _rebuild_firehose_pane!(m)
    elseif !isempty(added)
        if had_empty
            _rebuild_firehose_pane!(m)
        else
            for line in added
                push_line!(m.firehose_pane, line)
            end
        end
    end
    nothing
end
