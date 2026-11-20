module BlueskyTUI

using ATProto
using ATProto.Syntax: is_valid_handle, is_valid_did, rkey
using Dates
using JSON
using Printf
using Tachikoma
using Tachikoma: AbstractColor, NoColor

@tachikoma_app

include("rendering.jl")
include("state.jl")
include("actions.jl")
include("tabs.jl")
include("modals.jl")
include("events.jl")

export BlueskyModel, run_tui

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
