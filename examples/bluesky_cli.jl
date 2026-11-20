#!/usr/bin/env julia

#=
bluesky_cli.jl — End-to-end Bluesky terminal client built with ATProto.jl.

Demonstrates:
  - Bidirectional identity resolution (`resolve_identity`)
  - Public XRPC queries & lazy cursor pagination (`get_profile`, `eachitem`, `get_post_thread`)
  - Typed generated Lexicon structs & open-union embeds (`ATProto.API`)
  - RichText facet detection, grapheme counting & ANSI segment rendering (`ATProto.RichText`)
  - Authenticated PDS posting (`login!`, `post!`) with `--dry-run` preview
  - Real-time Jetstream WebSocket firehose streaming (`subscribe_jetstream`)

Usage:
  julia --project=. examples/bluesky_cli.jl profile bsky.app
  julia --project=. examples/bluesky_cli.jl feed bsky.app --limit 5
  julia --project=. examples/bluesky_cli.jl thread at://did:plc:.../app.bsky.feed.post/...
  julia --project=. examples/bluesky_cli.jl firehose --count 10 --filter julia
  julia --project=. examples/bluesky_cli.jl post "🚀 Hello @bsky.app https://julialang.org #JuliaLang" --dry-run
=#

using ATProto
using Dates
using Printf

# ANSI colors for terminal rendering
const _RESET   = "\e[0m"
const _BOLD    = "\e[1m"
const _DIM     = "\e[2m"
const _CYAN    = "\e[36m"
const _BLUE    = "\e[34m"
const _MAGENTA = "\e[35m"
const _GREEN   = "\e[32m"
const _YELLOW  = "\e[33m"

function print_usage()
    println("""
    ATProto.jl Bluesky CLI Example

    Commands:
      profile  <handle-or-did>                      Resolve & display an account profile
      feed     <handle-or-did> [--limit N]          Fetch recent posts with RichText highlighting
      thread   <at-uri> [--depth N]                 Display a post thread tree
      firehose [--collection NSID] [--filter STR] [--count N]
                                                    Stream live Jetstream events
      post     "<text>" [--lang CODE] [--dry-run]   Publish a post (uses BSKY_HANDLE & BSKY_APP_PASSWORD)
      help                                          Show this help message
    """)
end

function render_ansi_richtext(text::AbstractString, facets)
    isnothing(facets) && return String(text)
    rt = RichTextDoc(text, facets)
    io = IOBuffer()
    for seg in segments(rt)
        if is_mention(seg)
            print(io, _CYAN, seg.text, _RESET)
        elseif is_link(seg)
            print(io, _BLUE, seg.text, _RESET)
        elseif is_tag(seg)
            print(io, _MAGENTA, seg.text, _RESET)
        else
            print(io, seg.text)
        end
    end
    return String(take!(io))
end

function summarize_embed(embed)
    isnothing(embed) && return ""
    if embed isa API.AppBskyEmbedImagesView
        n = length(embed.images)
        return " $(_DIM)[$(n) image$(n == 1 ? "" : "s")]$(_RESET)"
    elseif embed isa API.AppBskyEmbedVideoView
        return " $(_DIM)[video]$(_RESET)"
    elseif embed isa API.AppBskyEmbedExternalView
        return " $(_DIM)[link: $(embed.external.title)]$(_RESET)"
    elseif embed isa API.AppBskyEmbedRecordView
        return " $(_DIM)[quote post]$(_RESET)"
    elseif embed isa API.AppBskyEmbedRecordWithMediaView
        return " $(_DIM)[quote + media]$(_RESET)"
    elseif embed isa UnknownObject
        return " $(_DIM)[embed: $(something(lexicon_type(embed), "unknown"))]$(_RESET)"
    end
    return " $(_DIM)[embed]$(_RESET)"
end

function parse_flag(args::Vector{String}, flag::String, default)
    idx = findfirst(==(flag), args)
    isnothing(idx) && return default
    idx >= length(args) && error("Flag $flag requires a value")
    return args[idx + 1]
end

has_flag(args::Vector{String}, flag::String) = flag in args

function cmd_profile(args::Vector{String})
    isempty(args) && error("Usage: profile <handle-or-did>")
    target = args[1]

    pub = AtpAgent(PUBLIC_APPVIEW)
    prof = get_profile(pub, target)

    # Also run standalone bidirectional identity resolution
    id_info = try
        resolve_identity(prof.did)
    catch
        nothing
    end

    name = something(prof.displayName, String(prof.handle))
    println("$(_BOLD)$(name)$(_RESET) $(_CYAN)@$(prof.handle)$(_RESET)")
    println("$(_DIM)DID: $(prof.did)$(_RESET)")
    if !isnothing(id_info)
        badge = id_info.handle_verified ? "$(_GREEN)verified$(_RESET)" : "$(_YELLOW)unverified$(_RESET)"
        println("Identity: $badge  |  PDS: $(something(id_info.pds, "unknown"))")
    end
    println(
        "Followers: $(_BOLD)$(something(prof.followersCount, 0))$(_RESET)  |  " *
        "Following: $(_BOLD)$(something(prof.followsCount, 0))$(_RESET)  |  " *
        "Posts: $(_BOLD)$(something(prof.postsCount, 0))$(_RESET)",
    )
    if !isnothing(prof.description) && !isempty(prof.description)
        println("\n", prof.description)
    end
end

function cmd_feed(args::Vector{String})
    isempty(args) && error("Usage: feed <handle-or-did> [--limit N]")
    actor = args[1]
    limit = parse(Int, parse_flag(args, "--limit", "5"))

    pub = AtpAgent(PUBLIC_APPVIEW)
    page_size = min(limit, 50)
    items = collect(Iterators.take(
        eachitem(pub, API.App.Bsky.Feed.GetAuthorFeed; actor = actor, limit = page_size),
        limit,
    ))

    println("$(_BOLD)Latest $(length(items)) feed items for $(actor):$(_RESET)\n")
    for (i, item) in enumerate(items)
        post = item.post
        author = post.author
        rec = post.record
        repost_note = item.reason isa API.AppBskyFeedDefsReasonRepost ?
            " $(_DIM)(reposted by @$(item.reason.by.handle))$(_RESET)" : ""

        println("$(_BOLD)[$i] @$(author.handle)$(_RESET)$repost_note  $(_DIM)$(post.indexedAt)$(_RESET)")
        if rec isa API.AppBskyFeedPost
            println("  ", replace(render_ansi_richtext(rec.text, rec.facets), "\n" => "\n  "), summarize_embed(post.embed))
        else
            println("  $(_DIM)<non-post record: $(lexicon_type(rec))>$(_RESET)")
        end
        println(
            "  $(_DIM)♥ $(something(post.likeCount, 0))  ↻ $(something(post.repostCount, 0))  " *
            "💬 $(something(post.replyCount, 0))  $(post.uri)$(_RESET)\n",
        )
    end
end

function _print_thread_node(node, indent::Int = 0)
    pad = "  "^indent
    if node isa API.AppBskyFeedDefsThreadViewPost
        post = node.post
        rec = post.record
        text = rec isa API.AppBskyFeedPost ? render_ansi_richtext(rec.text, rec.facets) : "<record>"
        first_line = first(split(text, '\n'))
        println("$(pad)$(_CYAN)@$(post.author.handle)$(_RESET): $first_line $(_DIM)(♥ $(something(post.likeCount, 0)))$(_RESET)")
        if !isnothing(node.replies)
            for child in node.replies
                _print_thread_node(child, indent + 1)
            end
        end
    elseif node isa API.AppBskyFeedDefsNotFoundPost
        println("$(pad)$(_DIM)[post not found: $(node.uri)]$(_RESET)")
    elseif node isa API.AppBskyFeedDefsBlockedPost
        println("$(pad)$(_DIM)[blocked post: $(node.uri)]$(_RESET)")
    end
end

function cmd_thread(args::Vector{String})
    isempty(args) && error("Usage: thread <at-uri> [--depth N]")
    uri = parse(AtUri, args[1])
    depth = parse(Int, parse_flag(args, "--depth", "3"))

    pub = AtpAgent(PUBLIC_APPVIEW)
    out = get_post_thread(pub, uri; depth = depth)
    _print_thread_node(out.thread)
end

function cmd_firehose(args::Vector{String})
    col = parse_flag(args, "--collection", "app.bsky.feed.post")
    kw = parse_flag(args, "--filter", "")
    kw_lower = lowercase(kw)
    max_matches = parse(Int, parse_flag(args, "--count", "10"))

    println("$(_BOLD)Subscribing to Jetstream$(_RESET) (collection=$col, count=$max_matches$(isempty(kw) ? "" : ", filter=$(repr(kw))"))...")
    matched = 0
    seen = 0
    t0 = time()

    subscribe_jetstream(wanted_collections = [col], reconnect = true) do stream
        for ev in stream
            seen += 1
            if ev isa JetstreamCommitEvent && ev.operation === :create && ev.record isa API.AppBskyFeedPost
                txt = ev.record.text
                if isempty(kw_lower) || occursin(kw_lower, lowercase(txt))
                    matched += 1
                    preview = replace(first(txt, 120), "\n" => " ")
                    println("$(_GREEN)[#$matched]$(_RESET) $(_DIM)$(ev.did)$(_RESET)  $preview")
                    matched >= max_matches && break
                end
            elseif col != "app.bsky.feed.post"
                matched += 1
                println("$(_GREEN)[#$matched]$(_RESET) $(typeof(ev))  $(ev.did)")
                matched >= max_matches && break
            end
        end
        elapsed = max(time() - t0, 1e-6)
        @printf("\nProcessed %d events (%d matched) in %.2fs (%.1f events/s). Last cursor: %s\n",
                seen, matched, elapsed, seen / elapsed, string(last_cursor(stream)))
    end
end

function cmd_post(args::Vector{String})
    isempty(args) && error("Usage: post \"<text>\" [--lang en] [--dry-run]")
    text = args[1]
    lang = parse_flag(args, "--lang", "en")
    dry_run = has_flag(args, "--dry-run")

    g_len = grapheme_length(text)
    b_len = byte_length(text)
    g_len > 300 && error("Post exceeds Bluesky's 300-grapheme limit ($g_len graphemes)")
    b_len > 3000 && error("Post exceeds Bluesky's 3000-byte limit ($b_len bytes)")

    pub = AtpAgent(PUBLIC_APPVIEW)
    rt = richtext(pub, text)

    println("$(_BOLD)Post preview$(_RESET) ($g_len/300 graphemes, $b_len/3000 bytes):")
    println("  ", render_ansi_richtext(rt.text, rt.facets))
    println("$(_BOLD)Detected facets ($(length(rt.facets))):$(_RESET)")
    for f in rt.facets
        feat = first(f.features)
        span = "[$(f.index.byteStart):$(f.index.byteEnd)] $(repr(byte_slice(rt.text, f.index)))"
        println("  - $span -> $(lexicon_type(feat)) ($feat)")
    end

    if dry_run
        println("\n$(_YELLOW)--dry-run set; post was not published.$(_RESET)")
        return
    end

    handle = get(ENV, "BSKY_HANDLE", "")
    password = get(ENV, "BSKY_APP_PASSWORD", "")
    (isempty(handle) || isempty(password)) &&
        error("Set BSKY_HANDLE and BSKY_APP_PASSWORD environment variables (or pass --dry-run)")

    agent = AtpAgent()
    login!(agent, handle, password)
    out = post!(agent, rt; langs = [lang])
    println("\n$(_GREEN)Published!$(_RESET) URI: $(out.uri)  CID: $(out.cid)")
end

function main(args::Vector{String})
    if isempty(args) || args[1] in ("help", "-h", "--help")
        print_usage()
        return
    end
    cmd = args[1]
    rest = args[2:end]
    if cmd == "profile"
        cmd_profile(rest)
    elseif cmd == "feed"
        cmd_feed(rest)
    elseif cmd == "thread"
        cmd_thread(rest)
    elseif cmd == "firehose"
        cmd_firehose(rest)
    elseif cmd == "post"
        cmd_post(rest)
    else
        println(stderr, "Unknown command: $cmd\n")
        print_usage()
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
