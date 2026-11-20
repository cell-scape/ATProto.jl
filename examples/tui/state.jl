# state.jl — Constants, data structures, BlueskyModel, Tachikoma hooks, and pane rebuilders.

const TAB_FEED     = 1
const TAB_THREAD   = 2
const TAB_PROFILE  = 3
const TAB_NOTIFS   = 4
const TAB_CHAT     = 5
const TAB_FIREHOSE = 6

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

struct SavedFeedChoice
    label::String
    kind::Symbol         # :timeline, :bookmarks, :feed, :list, :author
    value::String        # AT-URI, actor handle, or "following"/"bookmarks"
    pinned::Bool
end

struct GalleryImage
    label::String
    alt::String
    fullsize::String
    thumb::String
    dims::String
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
    sec_ticks::Int
    quit::Bool
    last_theme_name::String
    ambient_bg::Bool
    scanlines::Bool
    dotwave::DotWaveBackground

    # Navigation & resizable split layouts
    tabs::TabBar
    feed_focus::Symbol              # :list or :detail
    feed_split::ResizableLayout
    chat_focus::Symbol              # :convos or :messages
    chat_split::ResizableLayout

    # Feed / Timeline / Search / Saved Feed / Bookmarks state (Tab 1)
    feed_mode::Symbol               # :author, :timeline, :search, :saved_feed, :list_feed, :bookmarks
    feed_actor::String
    feed_query::String
    feed_source_uri::String
    feed_source_label::String
    feed_entries::Vector{FeedEntry}
    feed_cursor::Union{String, Nothing}
    feed_list::SelectableList
    feed_card_offset::Int
    detail_pane::ScrollPane
    feed_req_id::Int
    bookmarked_uris::Set{String}

    # Saved feeds / lists switcher state
    saved_feeds::Vector{SavedFeedChoice}
    saved_feeds_list::SelectableList
    saved_feeds_req_id::Int

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

    # Notifications state (Tab 4)
    notifs::Vector{API.AppBskyNotificationListNotificationsNotification}
    notifs_cursor::Union{String, Nothing}
    notifs_unread::Int
    notifs_list::SelectableList
    notifs_pane::ScrollPane
    notifs_req_id::Int

    # Chat / DMs state (Tab 5)
    chat_convos::Vector{API.ChatBskyConvoDefsConvoView}
    chat_convos_list::SelectableList
    chat_active_convo_id::Union{String, Nothing}
    chat_messages::Vector{Any}
    chat_messages_pane::ScrollPane
    chat_convos_req_id::Int
    chat_msgs_req_id::Int
    chat_unread_total::Int
    chat_input::TextInput

    # Firehose (Jetstream) state (Tab 6)
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

    # Modals (:none, :goto, :search, :compose, :login, :feeds, :gallery, :chat_send, :help)
    modal::Symbol
    goto_input::TextInput
    search_input::TextInput
    compose_area::TextArea
    compose_reply_to::Union{API.AppBskyFeedDefsPostView, Nothing}
    compose_quote_of::Union{API.AppBskyFeedDefsPostView, Nothing}
    login_handle_input::TextInput
    login_pass_input::TextInput
    login_field::Int                # 1 = handle, 2 = password
    gallery_images::Vector{GalleryImage}
    gallery_idx::Int
    gallery_title::String

    # Notifications / status toast
    status_msg::String
    status_kind::Symbol             # :info, :success, :warning, :error
    status_ttl::Int

    # Cached layout rects for copy_rect (Ctrl+Y) & mouse hit-testing
    rect_feed_list::Rect
    rect_feed_cards_inner::Rect
    rect_feed_detail::Rect
    rect_chat_convos::Rect
    rect_chat_messages::Rect
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
            tstyle(:error),
            tstyle(:primary),
            tstyle(:success),
        ],
    )
end

function _tab_labels(notifs_unread::Int, chat_unread::Int)::Vector{String}
    n_lbl = notifs_unread > 0 ? "◈ 4 Notifs($notifs_unread)" : "◈ 4 Notifs"
    c_lbl = chat_unread > 0 ? "✉ 5 Chat($chat_unread)" : "✉ 5 Chat"
    return ["◈ 1 Feed", "⎇ 2 Thread", "◎ 3 Profile", n_lbl, c_lbl, "≈ 6 Firehose"]
end

function _update_tab_labels!(m::BlueskyModel)
    m.tabs.labels = _tab_labels(m.notifs_unread, m.chat_unread_total)
    nothing
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
        _tab_labels(0, 0);
        active = clamp(initial_tab, 1, 6),
        tab_style = _make_tab_style(),
    )
    feed_split = ResizableLayout(Horizontal, [Percent(45), Fill(1)]; min_pane_size = 24)
    chat_split = ResizableLayout(Horizontal, [Percent(36), Fill(1)]; min_pane_size = 22)
    feed_list = SelectableList(ListItem[]; focused = true, show_scrollbar = true)
    detail_pane = ScrollPane(
        Vector{Span}[[Span("◌ Select a post card to inspect RichText facets, embeds & ATProto metadata.", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    saved_feeds_list = SelectableList(ListItem[]; focused = true, show_scrollbar = true)
    thread_pane = ScrollPane(
        Vector{Span}[[Span("◌ Press Enter or [t] on any post in the Feed tab to open its thread tree.", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    profile_pane = ScrollPane(
        Vector{Span}[[Span("◌ Loading profile & verifying DID document…", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    notifs_list = SelectableList(ListItem[]; focused = true, show_scrollbar = true)
    notifs_pane = ScrollPane(
        Vector{Span}[[Span("◌ Sign in with [L] and press [r] to load notifications.", tstyle(:text_dim))]];
        following = false, word_wrap = true,
    )
    chat_convos_list = SelectableList(ListItem[]; focused = true, show_scrollbar = true)
    chat_messages_pane = ScrollPane(
        Vector{Span}[[Span("◌ Sign in with [L] and press [r] to load Bluesky Chat DMs.", tstyle(:text_dim))]];
        following = true, word_wrap = true,
    )
    chat_input = TextInput(label = "DM: ", focused = true)
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
        0,
        false,
        theme().name,
        ambient_bg,
        scanlines,
        DotWaveBackground(; preset = 1, amplitude = 2.6, cam_height = 6.5),
        tabs,
        :list,
        feed_split,
        :convos,
        chat_split,
        :author,
        String(initial_actor),
        "",
        "",
        "",
        FeedEntry[],
        nothing,
        feed_list,
        0,
        detail_pane,
        0,
        Set{String}(),
        SavedFeedChoice[],
        saved_feeds_list,
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
        API.AppBskyNotificationListNotificationsNotification[],
        nothing,
        0,
        notifs_list,
        notifs_pane,
        0,
        API.ChatBskyConvoDefsConvoView[],
        chat_convos_list,
        nothing,
        Any[],
        chat_messages_pane,
        0,
        0,
        0,
        chat_input,
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
        nothing,
        login_handle_input,
        login_pass_input,
        1,
        GalleryImage[],
        1,
        "",
        "Deck online — press ? for keybindings",
        :info,
        0,
        Rect(),
        Rect(),
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
    elseif m.tabs.active == TAB_CHAT
        return m.chat_focus === :messages ? m.rect_chat_messages : m.rect_chat_convos
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
            if is_authenticated(m.agent)
                _fetch_unread_count!(m)
            end
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

function _selected_notif(m::BlueskyModel)::Union{API.AppBskyNotificationListNotificationsNotification, Nothing}
    isempty(m.notifs) && return nothing
    idx = clamp(m.notifs_list.selected, 1, length(m.notifs))
    return m.notifs[idx]
end

function _selected_convo(m::BlueskyModel)::Union{API.ChatBskyConvoDefsConvoView, Nothing}
    isempty(m.chat_convos) && return nothing
    idx = clamp(m.chat_convos_list.selected, 1, length(m.chat_convos))
    return m.chat_convos[idx]
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
        elseif m.feed_mode === :bookmarks
            "◌ No bookmarked posts yet — press [B] on any post to bookmark it."
        elseif m.feed_mode === :saved_feed || m.feed_mode === :list_feed
            "◌ Feed $(repr(m.feed_source_label)) has no posts yet — press [r] to refresh."
        else
            "◌ No posts loaded yet — press [r] refresh or [g] go to an actor."
        end
        set_content!(m.detail_pane, Vector{Span}[[Span(msg, tstyle(:text_dim))]])
    else
        is_bm = string(entry.post.uri) in m.bookmarked_uris
        set_content!(m.detail_pane, post_detail_lines(entry; bookmarked = is_bm))
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

function _rebuild_notifs_pane!(m::BlueskyModel; reset_scroll::Bool = false)
    prev_sel = m.notifs_list.selected
    m.notifs_list.items = [notif_to_list_item(n) for n in m.notifs]
    m.notifs_list.selected = clamp(prev_sel, 1, max(1, length(m.notifs)))
    if isempty(m.notifs)
        msg = is_authenticated(m.agent) ?
            "◌ No notifications yet — press [r] to refresh." :
            "◌ Sign in with [L] to view your Bluesky notifications."
        set_content!(m.notifs_pane, Vector{Span}[[Span(msg, tstyle(:text_dim))]])
    else
        set_content!(m.notifs_pane, notifs_to_span_lines(m.notifs, m.notifs_list.selected))
    end
    if reset_scroll
        m.notifs_pane.offset = 0
        m.notifs_pane.following = false
    end
    nothing
end

function _rebuild_chat_panes!(m::BlueskyModel; reset_scroll::Bool = false)
    my_did = let s = session(m.agent)
        isnothing(s) ? "" : String(s.did)
    end
    prev_sel = m.chat_convos_list.selected
    m.chat_convos_list.items = [convo_to_list_item(c, my_did) for c in m.chat_convos]
    m.chat_convos_list.selected = clamp(prev_sel, 1, max(1, length(m.chat_convos)))
    m.chat_unread_total = sum(c.unreadCount for c in m.chat_convos; init = 0)
    _update_tab_labels!(m)

    convo = _selected_convo(m)
    if !is_authenticated(m.agent)
        set_content!(m.chat_messages_pane, Vector{Span}[[
            Span("◌ Sign in with [L] to open Bluesky Chat DMs (via atproto-proxy).", tstyle(:text_dim)),
        ]])
    elseif isnothing(convo)
        set_content!(m.chat_messages_pane, Vector{Span}[[
            Span("◌ No conversations loaded — press [r] to refresh.", tstyle(:text_dim)),
        ]])
    elseif isempty(m.chat_messages)
        set_content!(m.chat_messages_pane, Vector{Span}[[
            Span("◌ No messages in this conversation yet — press [c] to send a DM.", tstyle(:text_dim)),
        ]])
    else
        set_content!(m.chat_messages_pane, chat_messages_to_span_lines(convo, m.chat_messages, my_did))
    end
    if reset_scroll
        m.chat_messages_pane.following = true
    end
    nothing
end

function _rebuild_saved_feeds_list!(m::BlueskyModel)
    prev_sel = m.saved_feeds_list.selected
    m.saved_feeds_list.items = [saved_feed_to_list_item(sf) for sf in m.saved_feeds]
    m.saved_feeds_list.selected = clamp(prev_sel, 1, max(1, length(m.saved_feeds)))
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
    for (pane, thumb) in (
        (m.detail_pane, :accent),
        (m.thread_pane, :accent),
        (m.profile_pane, :accent),
        (m.notifs_pane, :error),
        (m.chat_messages_pane, :primary),
        (m.firehose_pane, :success),
    )
        pane.scrollbar_style = tstyle(:text_dim, dim = true)
        pane.scrollbar_thumb_style = tstyle(thumb)
    end
    _rebuild_feed_list!(m)
    _rebuild_detail_pane!(m; reset_scroll = false)
    _rebuild_thread_pane!(m; reset_scroll = false)
    _rebuild_profile_pane!(m; reset_scroll = false)
    _rebuild_notifs_pane!(m; reset_scroll = false)
    _rebuild_chat_panes!(m; reset_scroll = false)
    _rebuild_firehose_pane!(m)
    m.last_theme_name = theme().name
    nothing
end
