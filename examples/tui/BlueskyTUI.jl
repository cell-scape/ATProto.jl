module BlueskyTUI

using ATProto
using ATProto.Syntax: is_valid_handle, is_valid_did, rkey
using Dates
using Printf
using Tachikoma
using Tachikoma: AbstractColor, NoColor

@tachikoma_app

include("rendering.jl")

export BlueskyModel, run_tui

# ── Constants & Types ───────────────────────────────────────────────

const TAB_FEED     = 1
const TAB_THREAD   = 2
const TAB_PROFILE  = 3
const TAB_FIREHOSE = 4

const JETSTREAM_PRESETS = (
    (label = "Posts", collections = ["app.bsky.feed.post"]),
    (label = "Posts+Likes+Reposts", collections = ["app.bsky.feed.post", "app.bsky.feed.like", "app.bsky.feed.repost"]),
    (label = "All", collections = String[]),
)

const MAX_FIREHOSE_LINES = 500
const RATE_HISTORY_LEN   = 60

const PHOSPHOR_THEMES = (
    (name = "esper",       label = "Amber CRT"),
    (name = "neuromancer", label = "P31 Green CRT"),
    (name = "kokaku",      label = "Cyber Blue CRT"),
    (name = "outrun",      label = "Synthwave CRT"),
    (name = "catppuccin",  label = "Comfy Pastel"),
    (name = "paper",       label = "Beige Terminal"),
)

struct JetstreamItem
    kind::Symbol         # :post, :like, :repost, :other
    did::String
    collection::String
    operation::Symbol
    text::String
    facets::Any
    time_us::Union{Int64, Nothing}
end

# ── Model ───────────────────────────────────────────────────────────

mutable struct BlueskyModel <: Model
    # ATProto client & startup flags
    agent::AtpAgent
    auto_fetch::Bool
    auto_timer::Bool
    auto_login::Bool

    # Async infrastructure & visual state
    queue::TaskQueue
    timer_token::Union{CancelToken, Nothing}
    tick::Int
    quit::Bool
    last_theme_name::String
    ambient_bg::Bool
    scanlines::Bool
    dotwave::DotWaveBackground

    # Navigation & resizable split layout
    tabs::TabBar
    feed_focus::Symbol              # :list or :detail
    feed_split::ResizableLayout

    # Feed / Timeline / Search state (Tab 1)
    feed_mode::Symbol               # :author, :timeline, :search
    feed_actor::String
    feed_query::String
    feed_entries::Vector{FeedEntry}
    feed_cursor::Union{String, Nothing}
    feed_list::SelectableList       # tracks selected index cleanly
    feed_card_offset::Int           # 0-based card viewport offset
    detail_pane::ScrollPane
    feed_req_id::Int

    # Thread state (Tab 2)
    thread_uri::Union{AtUri, Nothing}
    thread_root::Any
    thread_posts::Vector{API.AppBskyFeedDefsPostView}
    thread_pane::ScrollPane
    thread_req_id::Int

    # Profile state (Tab 3)
    profile_actor::String
    profile_data::Union{API.AppBskyActorDefsProfileViewDetailed, Nothing}
    profile_identity::Union{ATProto.Identity.ResolvedIdentity, Nothing}
    profile_pane::ScrollPane
    profile_req_id::Int
    identity_resolver::Function

    # Firehose (Jetstream) state (Tab 4)
    firehose_running::Bool
    firehose_preset_idx::Int
    firehose_filter::String
    firehose_pane::ScrollPane
    firehose_items::Vector{JetstreamItem}
    firehose_total::Int
    firehose_matched::Int
    firehose_posts::Int
    firehose_likes::Int
    firehose_reposts::Int
    firehose_cursor::Union{Int64, Nothing}
    firehose_sec_count::Int
    firehose_rate_history::Vector{Float64}
    jetstream_cancel::Union{CancelToken, Nothing}
    jetstream_stream::Ref{Any}
    jetstream_connector::Function

    # Modals (:none, :goto, :search, :compose, :login, :help)
    modal::Symbol
    goto_input::TextInput
    search_input::TextInput
    compose_area::TextArea
    compose_reply_to::Union{API.AppBskyFeedDefsPostView, Nothing}
    login_handle_input::TextInput
    login_pass_input::TextInput
    login_field::Int                # 1 = handle, 2 = password

    # Notifications / status
    status_msg::String
    status_kind::Symbol             # :info, :success, :warning, :error
    status_ttl::Int

    # Cached layout rects for copy_rect (Ctrl+Y) & mouse hit-testing
    rect_feed_list::Rect
    rect_feed_cards_inner::Rect
    rect_feed_detail::Rect
    rect_main_body::Rect
end

function _validate_actor_input(s::String)::Union{String, Nothing}
    t = strip(s)
    isempty(t) && return nothing
    cleaned = startswith(t, "@") ? t[2:end] : t
    if is_valid_handle(cleaned) || is_valid_did(cleaned)
        return nothing
    end
    return "Enter a valid handle (e.g. bsky.app) or DID (did:plc:...)"
end

function _default_jetstream_connector(collections::Vector{String})
    if isempty(collections)
        return subscribe_jetstream(; reconnect = true)
    else
        return subscribe_jetstream(; wanted_collections = collections, reconnect = true)
    end
end

function _make_tab_style()
    return TabBarStyle(
        decoration = BoxTabs(box = BOX_ROUNDED),
        active = tstyle(:accent, bold = true),
        inactive = tstyle(:text_dim),
        tab_colors = [
            tstyle(:primary),
            tstyle(:accent),
            tstyle(:warning),
            tstyle(:success),
        ],
    )
end

function BlueskyModel(;
    agent::AtpAgent = AtpAgent(PUBLIC_APPVIEW),
    initial_actor::AbstractString = "bsky.app",
    initial_tab::Int = TAB_FEED,
    auto_fetch::Bool = true,
    auto_timer::Bool = true,
    auto_login::Bool = true,
    ambient_bg::Bool = true,
    scanlines::Bool = true,
    jetstream_connector::Function = _default_jetstream_connector,
    identity_resolver::Function = resolve_identity,
)
    tabs = TabBar(
        ["◈ 1 Feed", "⎇ 2 Thread", "◎ 3 Profile", "≈ 4 Firehose"];
        active = clamp(initial_tab, 1, 4),
        tab_style = _make_tab_style(),
    )
    feed_split = ResizableLayout(Horizontal, [Percent(45), Fill(1)]; min_pane_size = 24)
    feed_list = SelectableList(ListItem[]; focused = true, show_scrollbar = true)
    detail_pane = ScrollPane(
        Vector{Span}[[Span("◌ Select a post card to inspect RichText facets, embeds & ATProto metadata.", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    thread_pane = ScrollPane(
        Vector{Span}[[Span("◌ Press Enter or [t] on any post in the Feed tab to open its thread tree.", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    profile_pane = ScrollPane(
        Vector{Span}[[Span("◌ Loading profile & verifying DID document…", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    firehose_pane = ScrollPane(
        Vector{Span}[[Span("◌ Press [Space] to tune into the live Bluesky Jetstream WebSocket firehose.", tstyle(:text_dim))]];
        following = true, word_wrap = true,
    )

    goto_input = TextInput(
        label = "Actor: ",
        focused = true,
        validator = _validate_actor_input,
    )
    search_input = TextInput(label = "Query: ", focused = true)
    compose_area = TextArea(focused = true)
    login_handle_input = TextInput(label = "Handle:   ", focused = true)
    login_pass_input = TextInput(label = "Password: ", focused = false)

    BlueskyModel(
        agent,
        auto_fetch,
        auto_timer,
        auto_login,
        TaskQueue(; capacity = 512),
        nothing,
        0,
        false,
        theme().name,
        ambient_bg,
        scanlines,
        DotWaveBackground(; preset = 1, amplitude = 2.6, cam_height = 6.5),
        tabs,
        :list,
        feed_split,
        :author,
        String(initial_actor),
        "",
        FeedEntry[],
        nothing,
        feed_list,
        0,
        detail_pane,
        0,
        nothing,
        nothing,
        API.AppBskyFeedDefsPostView[],
        thread_pane,
        0,
        String(initial_actor),
        nothing,
        nothing,
        profile_pane,
        0,
        identity_resolver,
        false,
        1,
        "",
        firehose_pane,
        JetstreamItem[],
        0,
        0,
        0,
        0,
        0,
        nothing,
        0,
        zeros(Float64, RATE_HISTORY_LEN),
        nothing,
        Ref{Any}(nothing),
        jetstream_connector,
        :none,
        goto_input,
        search_input,
        compose_area,
        nothing,
        login_handle_input,
        login_pass_input,
        1,
        "Deck online — press ? for keybindings",
        :info,
        0,
        Rect(),
        Rect(),
        Rect(),
        Rect(),
    )
end

# ── Tachikoma Model Hooks ───────────────────────────────────────────

should_quit(m::BlueskyModel) = m.quit
task_queue(m::BlueskyModel) = m.queue
set_wake!(m::BlueskyModel, notify::Function) = (m.queue.on_ready = notify; nothing)

function copy_rect(m::BlueskyModel)
    if m.tabs.active == TAB_FEED
        return m.feed_focus === :detail ? m.rect_feed_detail : m.rect_feed_list
    end
    return m.rect_main_body.width > 0 ? m.rect_main_body : nothing
end

function init!(m::BlueskyModel, ::Terminal)
    if m.auto_timer && m.timer_token === nothing
        m.timer_token = spawn_timer!(m.queue, :tick_1s, 1.0; repeat = true)
    end
    if m.auto_fetch
        h = get(ENV, "BSKY_HANDLE", "")
        pw = get(ENV, "BSKY_APP_PASSWORD", "")
        if m.auto_login && !isempty(h) && !isempty(pw) && !is_authenticated(m.agent)
            _start_login!(m, h, pw)
        else
            _fetch_feed!(m; append = false)
            _fetch_profile!(m, m.profile_actor)
        end
    end
    nothing
end

function cleanup!(m::BlueskyModel)
    if m.timer_token !== nothing
        cancel!(m.timer_token)
        m.timer_token = nothing
    end
    _stop_firehose!(m)
    nothing
end

# ── Status Toast Helper ─────────────────────────────────────────────

function _notify!(m::BlueskyModel, msg::AbstractString, kind::Symbol = :info; ttl::Int = 240)
    m.status_msg = String(msg)
    m.status_kind = kind
    m.status_ttl = ttl
    nothing
end

# ── Rebuild Pane Content ────────────────────────────────────────────

function _selected_entry(m::BlueskyModel)::Union{FeedEntry, Nothing}
    isempty(m.feed_entries) && return nothing
    idx = clamp(m.feed_list.selected, 1, length(m.feed_entries))
    return m.feed_entries[idx]
end

function _rebuild_feed_list!(m::BlueskyModel)
    prev_sel = m.feed_list.selected
    m.feed_list.items = [feed_entry_to_list_item(e) for e in m.feed_entries]
    m.feed_list.selected = clamp(prev_sel, 1, max(1, length(m.feed_entries)))
    _rebuild_detail_pane!(m; reset_scroll = false)
    nothing
end

function _rebuild_detail_pane!(m::BlueskyModel; reset_scroll::Bool = true)
    entry = _selected_entry(m)
    if isnothing(entry)
        msg = if m.feed_mode === :search
            "◌ No search results for $(repr(m.feed_query))."
        elseif m.feed_mode === :timeline
            "◌ Timeline is empty — press [r] to refresh."
        else
            "◌ No posts loaded yet — press [r] refresh or [g] go to an actor."
        end
        set_content!(m.detail_pane, Vector{Span}[[Span(msg, tstyle(:text_dim))]])
    else
        set_content!(m.detail_pane, post_detail_lines(entry))
    end
    if reset_scroll
        m.detail_pane.offset = 0
        m.detail_pane.following = false
    end
    nothing
end

function _rebuild_thread_pane!(m::BlueskyModel; reset_scroll::Bool = true)
    if isnothing(m.thread_root)
        set_content!(m.thread_pane, Vector{Span}[[
            Span("◌ Press Enter or [t] on any post in the Feed tab to inspect its thread.", tstyle(:text_dim)),
        ]])
        empty!(m.thread_posts)
    else
        lines, posts = thread_to_span_lines(m.thread_root)
        m.thread_posts = posts
        set_content!(m.thread_pane, lines)
    end
    if reset_scroll
        m.thread_pane.offset = 0
        m.thread_pane.following = false
    end
    nothing
end

function _rebuild_profile_pane!(m::BlueskyModel; reset_scroll::Bool = true)
    if isnothing(m.profile_data)
        set_content!(m.profile_pane, Vector{Span}[[
            Span("◌ Loading profile for $(m.profile_actor)…", tstyle(:text_dim)),
        ]])
    else
        set_content!(m.profile_pane, profile_to_span_lines(m.profile_data, m.profile_identity))
    end
    if reset_scroll
        m.profile_pane.offset = 0
        m.profile_pane.following = false
    end
    nothing
end

function _format_jetstream_line(item::JetstreamItem)::Vector{Span}
    dim_s = tstyle(:text_dim)
    short_did = length(item.did) > 22 ? first(item.did, 20) * "…" : item.did
    ts = if !isnothing(item.time_us)
        Dates.format(unix2datetime(item.time_us / 1e6), dateformat"HH:MM:SS")
    else
        Dates.format(now(UTC), dateformat"HH:MM:SS")
    end

    if item.kind === :post
        spans = Span[
            Span("$ts ", dim_s),
            Span(" POST ", _chip_style(:primary)),
            Span(" ", dim_s),
            Span(short_did, tstyle(:accent, hyperlink = bsky_profile_url(item.did))),
            Span(" │ ", dim_s),
        ]
        one_line = safe_one_line(item.text)
        if !isnothing(item.facets) && !isempty(item.facets)
            segs = collect(segments(RichTextDoc(item.text, item.facets)))
            for seg in segs
                txt = replace(seg.text, r"[\r\n\t]+" => " ")
                isempty(txt) && continue
                push!(spans, Span(txt, segment_style(seg)))
            end
        else
            push!(spans, Span(one_line, tstyle(:text)))
        end
        return spans
    elseif item.kind === :like
        return Span[
            Span("$ts ", dim_s),
            Span(" ♥ LIKE ", _chip_style(:error)),
            Span(" $short_did", dim_s),
            Span(" ($(item.operation))", dim_s),
        ]
    elseif item.kind === :repost
        return Span[
            Span("$ts ", dim_s),
            Span(" ↻ RPST ", _chip_style(:success)),
            Span(" $short_did", dim_s),
            Span(" ($(item.operation))", dim_s),
        ]
    else
        return Span[
            Span("$ts ", dim_s),
            Span(" $(truncate_chars(item.collection, 18)) ", _chip_style(:warning)),
            Span(" $short_did", dim_s),
            Span(" ($(item.operation))", dim_s),
        ]
    end
end

function _rebuild_firehose_pane!(m::BlueskyModel)
    if isempty(m.firehose_items)
        msg = m.firehose_running ?
            "◉ Connected to Jetstream — awaiting matching commits…" :
            "◌ Press [Space] to tune into the live Bluesky Jetstream WebSocket firehose."
        set_content!(m.firehose_pane, Vector{Span}[[Span(msg, tstyle(:text_dim))]])
    else
        lines = [_format_jetstream_line(it) for it in m.firehose_items]
        set_content!(m.firehose_pane, lines)
    end
    nothing
end

function _retheme_all!(m::BlueskyModel)
    m.tabs.tab_style = _make_tab_style()
    m.detail_pane.scrollbar_style = tstyle(:text_dim, dim = true)
    m.detail_pane.scrollbar_thumb_style = tstyle(:accent)
    m.thread_pane.scrollbar_style = tstyle(:text_dim, dim = true)
    m.thread_pane.scrollbar_thumb_style = tstyle(:accent)
    m.profile_pane.scrollbar_style = tstyle(:text_dim, dim = true)
    m.profile_pane.scrollbar_thumb_style = tstyle(:accent)
    m.firehose_pane.scrollbar_style = tstyle(:text_dim, dim = true)
    m.firehose_pane.scrollbar_thumb_style = tstyle(:success)
    _rebuild_feed_list!(m)
    _rebuild_detail_pane!(m; reset_scroll = false)
    _rebuild_thread_pane!(m; reset_scroll = false)
    _rebuild_profile_pane!(m; reset_scroll = false)
    _rebuild_firehose_pane!(m)
    m.last_theme_name = theme().name
    nothing
end

# ── Async Data Fetchers ─────────────────────────────────────────────

function _fetch_feed!(m::BlueskyModel; append::Bool = false, silent::Bool = false)
    m.feed_req_id += 1
    req_id = m.feed_req_id
    mode = m.feed_mode
    actor = m.feed_actor
    query = m.feed_query
    cursor = append ? m.feed_cursor : nothing
    agent = m.agent

    if append && isnothing(cursor)
        silent || _notify!(m, "Reached end of feed", :warning)
        return
    end

    label = mode === :timeline ? "timeline" : mode === :search ? "search $(repr(query))" : "@$actor"
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
        else
            out = get_author_feed(agent, actor; limit = 25, cursor = cursor)
            entries = [FeedEntry(item) for item in out.feed]
            return (req_id = req_id, append = append, silent = silent, entries = entries, cursor = out.cursor, label = label)
        end
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
    agent = m.agent
    m.modal = :none
    m.compose_reply_to = nothing

    if !is_authenticated(agent)
        n_m = length(detect_mentions(txt))
        n_l = length(detect_links(txt))
        n_t = length(detect_tags(txt))
        _notify!(m, "Dry-run OK ($g_len gr, $(n_m)m/$(n_l)l/$(n_t)t) — press L to log in & publish", :warning; ttl = 360)
        return
    end

    _notify!(m, isnothing(reply_post) ? "Publishing post…" : "Publishing reply…", :info)
    spawn_task!(m.queue, :post_done) do
        rt = richtext(agent, txt)
        reply_ref = if !isnothing(reply_post)
            parent_ref = API.ComAtprotoRepoStrongRef(uri = reply_post.uri, cid = reply_post.cid)
            root_ref = if reply_post.record isa API.AppBskyFeedPost && !isnothing(reply_post.record.reply)
                reply_post.record.reply.root
            else
                parent_ref
            end
            API.AppBskyFeedPostReplyRef(root = root_ref, parent = parent_ref)
        else
            nothing
        end
        out = post!(agent, rt; reply = reply_ref, langs = ["en"])
        return (uri = out.uri, is_reply = !isnothing(reply_post))
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
            ts = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
            rec = API.AppBskyFeedLike(
                subject = API.ComAtprotoRepoStrongRef(uri = post.uri, cid = post.cid),
                createdAt = ts,
            )
            out = create_record(agent, "app.bsky.feed.like", rec)
            return (post_uri = post.uri, like_uri = out.uri, liked = true)
        else
            rk = ATProto.Syntax.rkey(existing)
            isnothing(rk) && error("Cannot extract record key from like URI")
            delete_record(agent, "app.bsky.feed.like", rk)
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
            ts = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
            rec = API.AppBskyFeedRepost(
                subject = API.ComAtprotoRepoStrongRef(uri = post.uri, cid = post.cid),
                createdAt = ts,
            )
            out = create_record(agent, "app.bsky.feed.repost", rec)
            return (post_uri = post.uri, repost_uri = out.uri, reposted = true)
        else
            rk = ATProto.Syntax.rkey(existing)
            isnothing(rk) && error("Cannot extract record key from repost URI")
            delete_record(agent, "app.bsky.feed.repost", rk)
            return (post_uri = post.uri, repost_uri = nothing, reposted = false)
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

# ── TaskEvent Handling ──────────────────────────────────────────────

function _format_err(e)::String
    if e isa XRPCError
        return "$(e.error): $(something(e.message, "HTTP $(e.status)"))"
    elseif e isa AuthError
        return "Auth error: $(e.msg)"
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

function update!(m::BlueskyModel, evt::TaskEvent)
    val = evt.value
    if evt.id === :tick_1s
        push!(m.firehose_rate_history, Float64(m.firehose_sec_count))
        while length(m.firehose_rate_history) > RATE_HISTORY_LEN
            popfirst!(m.firehose_rate_history)
        end
        m.firehose_sec_count = 0
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
        m.feed_cursor = val.cursor
        _rebuild_feed_list!(m)
        _rebuild_detail_pane!(m; reset_scroll = !val.append)
        val.silent || _notify!(m, "Loaded $(length(val.entries)) posts ($(val.label))", :success)

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

    elseif evt.id === :login_done
        m.agent = val.agent
        h = String(val.session.handle)
        m.feed_mode = :timeline
        m.feed_actor = h
        m.profile_actor = h
        _notify!(m, "Signed in as @$h (PDS: $(service_url(m.agent)))", :success)
        _fetch_feed!(m; append = false, silent = true)
        _fetch_profile!(m, h; silent = true)

    elseif evt.id === :post_done
        kind = val.is_reply ? "Reply" : "Post"
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
    end
    nothing
end

# ── Modal Key Handling ──────────────────────────────────────────────

function _handle_modal_key!(m::BlueskyModel, evt::KeyEvent)
    if evt.key == :escape
        m.modal = :none
        m.compose_reply_to = nothing
        return nothing
    end

    if m.modal === :help
        if evt.key == :enter || (evt.key == :char && evt.char in ('?', 'q'))
            m.modal = :none
        end
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

# ── Main KeyEvent Handling ──────────────────────────────────────────

function _open_compose!(m::BlueskyModel; reply_to::Union{API.AppBskyFeedDefsPostView, Nothing} = nothing)
    set_text!(m.compose_area, "")
    m.compose_area.focused = true
    m.compose_reply_to = reply_to
    m.modal = :compose
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

function update!(m::BlueskyModel, evt::KeyEvent)
    if evt.key == :ctrl_c
        m.quit = true
        return nothing
    end

    if m.modal !== :none
        _handle_modal_key!(m, evt)
        return nothing
    end

    # Global deck shortcuts
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
            m.tabs.active = TAB_FEED
            return nothing
        elseif ch == '2'
            m.tabs.active = TAB_THREAD
            return nothing
        elseif ch == '3'
            m.tabs.active = TAB_PROFILE
            return nothing
        elseif ch == '4'
            m.tabs.active = TAB_FIREHOSE
            return nothing
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
        elseif ch == 'c'
            _open_compose!(m)
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
        elseif evt.key == :char && evt.char == 'p'
            entry = _selected_entry(m)
            isnothing(entry) || _open_compose!(m; reply_to = entry.post)
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
        elseif evt.key == :char && evt.char == 'r'
            _fetch_profile!(m, m.profile_actor)
        else
            handle_key!(m.profile_pane, _nav_key(evt))
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

# ── MouseEvent Handling ─────────────────────────────────────────────

function update!(m::BlueskyModel, evt::MouseEvent)
    m.modal !== :none && return nothing

    if handle_mouse!(m.tabs, evt) === :changed
        return nothing
    end

    tab = m.tabs.active
    if tab == TAB_FEED
        # Draggable split border takes priority!
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
    elseif tab == TAB_FIREHOSE
        handle_mouse!(m.firehose_pane, evt)
    end
    nothing
end

# ── Retro-Future Comfy Chrome & Views ───────────────────────────────

function _render_deck_header!(m::BlueskyModel, rect::Rect, buf::Buffer)
    (rect.width < 10 || rect.height < 1) && return
    y = rect.y
    c1 = color_lerp(_canvas_bg_rgb(), to_rgb(theme().primary), light_mode() ? 0.14 : 0.22)
    c2 = _canvas_bg_rgb()
    fill_gradient!(buf, rect, c1, c2; direction = :horizontal)

    # Left: Retro Deck emblem + ATProto.jl + breathing phosphor LED / spinner
    cx = rect.x + 1
    rx = right(rect) - 1
    cx = set_string!(buf, cx, y, " ◈ BSKY·DECK ", _inverted_pill_style(:primary); max_x = rx)
    cx = set_string!(buf, cx, y, "  ATProto.jl ", Style(fg = theme().title, bold = true); max_x = rx)

    is_busy = m.queue.active[] > (m.timer_token === nothing ? 0 : 1)
    if is_busy
        spin = SPINNER_DOTS[mod1((m.tick ÷ 3) + 1, length(SPINNER_DOTS))]
        cx = set_string!(buf, cx, y, " $spin SYNC ", _chip_style(:accent); max_x = rx)
    else
        # Gentle organic breathing LED
        led_rgb = to_rgb(m.firehose_running ? theme().success : theme().accent)
        if animations_enabled()
            b = breathe(m.tick; period = 110)
            led_rgb = brighten(led_rgb, b * 0.35)
        end
        cx = set_string!(buf, cx, y, "◉", Style(fg = led_rgb, bold = true); max_x = rx)
    end

    # Right: UTC deck clock + auth badge
    clock_str = Dates.format(now(UTC), dateformat"HH:MM:SS") * "Z"
    right_spans = if is_authenticated(m.agent)
        sess = session(m.agent)
        h = isnothing(sess) ? "authenticated" : "@$(sess.handle)"
        Span[
            Span(" ● $h ", _chip_style(:success)),
            Span("  $clock_str ", Style(fg = theme().text_dim)),
        ]
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
    # Stamp subtle CRT hardware telemetry in right-hand open space on middle tab row
    if rect.height >= 3 && rect.width > 74
        y_mid = rect.y + 1
        scan_lbl = m.scanlines ? "▤ CRT" : "▢ LCD"
        wave_lbl = m.ambient_bg ? "≈ Waves" : "◌ Flat"
        badge = " $scan_lbl · $wave_lbl · ◈ $(theme().name) "
        tx = right(rect) - textwidth(badge)
        if tx > rect.x + 62
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
    else
        "@$(truncate_chars(m.feed_actor, 16)) ($(length(m.feed_entries)))"
    end
    more_hint = isnothing(m.feed_cursor) ? "" : "[n] More"

    # Left: Ancient PC Desktop Unit (AT-5150) with 5.25" Floppy Drive Bay & track readout!
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
    )

    # Right: Boxy Studio Broadcast CRT Tube Monitor (PVM-14) with rotary knobs & speaker grille!
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
        title_right = "Esc:Feed  p:Reply  o:Profile",
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
        title_right = "f:Load Feed  g:Actor  r:Refresh",
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

function _render_firehose_tab!(m::BlueskyModel, area::Rect, buf::Buffer)
    top_h = area.height >= 24 ? 9 : (area.height >= 18 ? 7 : 6)
    rows = split_layout(Layout(Vertical, [Fixed(top_h), Fill(1)]), area)
    top_cols = split_layout(Layout(Horizontal, [Percent(52), Fill(1)]), rows[1])
    m.rect_main_body = rows[2]

    # Top-left: Vintage Carrier Modem / Signal Receiver Deck (JS-MODEM)
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

    # Top-right: Tektronix 4010 Storage-Tube Oscilloscope (TEK-4010)
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

    # Bottom: Live Commits Ticker CRT Monitor (TTY-STREAM)
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

    # Right side first so we know exact remaining space for keycaps / toast
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

    # Left side: active toast pill OR contextual tactile keycap bar
    if m.status_ttl > 0 && !isempty(m.status_msg)
        field = m.status_kind === :error   ? :error :
                m.status_kind === :warning ? :warning :
                m.status_kind === :success ? :success : :accent
        icon = m.status_kind === :error ? "✕ " : m.status_kind === :warning ? "⚠ " : m.status_kind === :success ? "✓ " : "◈ "
        pill = " $icon$(m.status_msg) "
        set_string!(buf, rect.x + 1, y, pill, _chip_style(field); max_x = left_max)
    else
        pairs = if m.tabs.active == TAB_FEED
            [("j/k", "Nav"), ("Tab", "Pane"), ("↵", "Thread"), ("o", "Profile"), ("g", "Actor"), ("/", "Search"), ("c", "Post"), ("P", "Phosphor"), ("v", "CRT")]
        elseif m.tabs.active == TAB_THREAD
            [("j/k", "Scroll"), ("Esc", "Feed"), ("o", "Profile"), ("p", "Reply"), ("r", "Refresh"), ("P", "Phosphor")]
        elseif m.tabs.active == TAB_PROFILE
            [("j/k", "Scroll"), ("f", "Load Feed"), ("g", "Actor"), ("r", "Refresh"), ("P", "Phosphor")]
        else
            [("Space", "Tune/Stby"), ("/", "Filter"), ("C", "Preset"), ("x", "Wipe"), ("P", "Phosphor")]
        end
        render_keycap_bar!(buf, rect.x + 1, y, pairs; max_x = left_max, bg = sbg)
    end

    # Draw right-aligned spans
    rx2 = max(rect.x, right(rect) - rw + 1)
    for sp in right_spans
        rx2 > right(rect) && break
        rx2 = set_string!(buf, rx2, y, sp.content, sp.style; max_x = right(rect))
    end
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

    elseif m.modal === :compose
        title = isnothing(m.compose_reply_to) ? "Compose Post" : "Reply to @$(m.compose_reply_to.author.handle)"
        mode_tag = is_authenticated(m.agent) ? "LIVE PDS" : "DRY-RUN"
        inn = render_floating_modal!(buf, area, 76, 17; title = title, title_right = mode_tag, tick = m.tick)

        cur_y = inn.y
        if !isnothing(m.compose_reply_to)
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

        # Shimmering retro Gauge for 300-grapheme post budget!
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

        # Live RichText facet chips
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
            ("  1 / 2 / 3 / 4     Switch tabs (Feed / Thread / Profile / Firehose)", tstyle(:text)),
            ("  j/k or ↑/↓        Move post card selection or scroll active pane", tstyle(:text)),
            ("  Tab or ←/→        Switch focus between Post Cards & Post Inspector", tstyle(:text)),
            ("  Mouse Drag        Drag split border to resize (right-click resets)", tstyle(:text)),
            ("  Enter / t         Open thread tree for selected post", tstyle(:text)),
            ("  o / f             Open post author profile / Load profile's feed", tstyle(:text)),
            ("  n / r             Load next cursor page / Refresh active view", tstyle(:text)),
            ("", tstyle(:text)),
            ("◈ Actions & Modals", tstyle(:title, bold = true)),
            ("  g                 Go to any Bluesky handle or DID", tstyle(:text)),
            ("  /                 Search Bluesky posts (or filter Jetstream)", tstyle(:text)),
            ("  c / p             Compose new post / Reply to selected post", tstyle(:text)),
            ("  l / R / T         Like / Repost / Toggle Home Timeline (auth)", tstyle(:text)),
            ("  L                 Sign in with App Password (or Ctrl+O sign out)", tstyle(:text)),
            ("", tstyle(:text)),
            ("◈ Jetstream & Retro CRT Hardware", tstyle(:title, bold = true)),
            ("  Space / C / x     Connect or Standby / Cycle presets / Clear log", tstyle(:text)),
            ("  P / v / b         Cycle CRT phosphor / Toggle scanlines / DotWave", tstyle(:text)),
            ("  Ctrl+T            All 25+ themes (esper, neuromancer, kokaku, paper)", tstyle(:text)),
            ("  Ctrl+Y / Ctrl+R   Copy active pane / Record .tach session", tstyle(:text)),
        ]
        inn = render_floating_modal!(
            buf, area, 76, length(help_lines) + 5;
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

# ── Main View ───────────────────────────────────────────────────────

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

    # Base canvas + optional whisper-subtle retro-future DotWave terrain backdrop
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

    # Cozy 1-column breathing margin around the main workspace on wide terminals
    body_area = area.width >= 88 ? margin(rows[3]; left = 1, right = 1) : rows[3]

    tab = m.tabs.active
    if tab == TAB_FEED
        _render_feed_tab!(m, body_area, buf)
    elseif tab == TAB_THREAD
        _render_thread_tab!(m, body_area, buf)
    elseif tab == TAB_PROFILE
        _render_profile_tab!(m, body_area, buf)
    else
        _render_firehose_tab!(m, body_area, buf)
    end

    _render_status_bar!(m, rows[4], buf)

    if m.modal !== :none
        _render_modal!(m, area, buf)
    end
    nothing
end

# ── Entry Point ─────────────────────────────────────────────────────

function _apply_theme_by_name!(name::AbstractString)
    low = lowercase(strip(String(name)))
    isempty(low) && return
    for th in DARK_THEMES
        if lowercase(th.name) == low
            set_light_mode!(false)
            set_theme!(th)
            return
        end
    end
    for th in LIGHT_THEMES
        if lowercase(th.name) == low
            set_light_mode!(true)
            set_theme!(th)
            return
        end
    end
end

function run_tui(;
    actor::AbstractString = "bsky.app",
    tab::Int = TAB_FEED,
    theme_name::AbstractString = "esper",
    auto_login::Bool = true,
    ambient_bg::Bool = true,
    scanlines::Bool = true,
    fps::Int = 30,
    tty_out = nothing,
    tty_size = nothing,
)
    _apply_theme_by_name!(theme_name)
    model = BlueskyModel(;
        initial_actor = actor,
        initial_tab = tab,
        auto_login = auto_login,
        ambient_bg = ambient_bg,
        scanlines = scanlines,
    )
    app(model; fps = fps, tty_out = tty_out, tty_size = tty_size)
end

end # module BlueskyTUI
