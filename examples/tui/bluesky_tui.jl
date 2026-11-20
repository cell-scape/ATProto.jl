#!/usr/bin/env julia

#=
bluesky_tui.jl — Retro-future CRT Bluesky TUI deck built with ATProto.jl + Tachikoma.jl.

Usage:
  julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl [options]

Options:
  --actor <handle-or-did>   Initial actor to browse (default: bsky.app)
  --tab <name>              Initial tab: feed | thread | profile | firehose (default: feed)
  --theme <name>            Initial phosphor theme (default: esper; e.g. neuromancer, kokaku, outrun, catppuccin, paper)
  --no-waves                Disable ambient DotWave horizon backdrop
  --no-scanlines            Disable subtle CRT raster scanline shading
  --no-auto-login           Ignore BSKY_HANDLE / BSKY_APP_PASSWORD on startup
  -h, --help                Show this help message
=#

const _REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
if !(_REPO_ROOT in LOAD_PATH)
    push!(LOAD_PATH, _REPO_ROOT)
end

include(joinpath(@__DIR__, "BlueskyTUI.jl"))
using .BlueskyTUI

function _print_usage()
    println("""
    ATProto.jl · BSKY·DECK Retro CRT Bluesky TUI (powered by Tachikoma.jl)

    Usage:
      julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl [options]

    Options:
      --actor <handle-or-did>   Initial Bluesky account to browse (default: bsky.app)
      --tab <name>              Initial tab: feed | thread | profile | firehose (default: feed)
      --theme <name>            Initial phosphor theme (default: esper [Amber CRT];
                                press P to cycle CRT phosphors or Ctrl+T for all 25+ themes)
      --no-waves                Disable ambient DotWave horizon backdrop (toggle in-app with b)
      --no-scanlines            Disable subtle CRT raster scanlines (toggle in-app with v)
      --no-auto-login           Skip auto-login from BSKY_HANDLE / BSKY_APP_PASSWORD
      -h, --help                Print this help and exit

    Environment variables (optional):
      BSKY_HANDLE               Automatically sign in as this handle on startup
      BSKY_APP_PASSWORD         Bluesky App Password for authenticated timeline/posting/likes
    """)
end

function _parse_cli(args::Vector{String})
    actor = "bsky.app"
    tab = BlueskyTUI.TAB_FEED
    theme_name = "esper"
    auto_login = true
    ambient_bg = true
    scanlines = true
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            _print_usage()
            exit(0)
        elseif a == "--actor" && i < length(args)
            i += 1
            actor = args[i]
        elseif a == "--tab" && i < length(args)
            i += 1
            t = lowercase(args[i])
            tab = t == "feed"     ? BlueskyTUI.TAB_FEED :
                  t == "thread"   ? BlueskyTUI.TAB_THREAD :
                  t == "profile"  ? BlueskyTUI.TAB_PROFILE :
                  t == "firehose" ? BlueskyTUI.TAB_FIREHOSE :
                  error("Unknown --tab value: $(args[i]) (expected feed, thread, profile, or firehose)")
        elseif a == "--theme" && i < length(args)
            i += 1
            theme_name = args[i]
        elseif a == "--no-waves"
            ambient_bg = false
        elseif a == "--no-scanlines"
            scanlines = false
        elseif a == "--no-auto-login"
            auto_login = false
        elseif !startswith(a, "-")
            actor = a
        else
            error("Unknown option: $a (use --help for usage)")
        end
        i += 1
    end
    return (; actor, tab, theme_name, auto_login, ambient_bg, scanlines)
end

if abspath(PROGRAM_FILE) == @__FILE__
    opts = _parse_cli(ARGS)
    run_tui(;
        actor = opts.actor,
        tab = opts.tab,
        theme_name = opts.theme_name,
        auto_login = opts.auto_login,
        ambient_bg = opts.ambient_bg,
        scanlines = opts.scanlines,
    )
end
