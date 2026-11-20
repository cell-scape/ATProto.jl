# ATProto.jl Examples

CLI scripts run directly from the repository root with zero extra dependencies;
the interactive TUI viewer uses its own isolated sub-project (`examples/tui/Project.toml`)
so `Tachikoma.jl` stays out of core `ATProto.jl` dependencies.

## 1. Retro-Future CRT Bluesky TUI Deck ([`tui/bluesky_tui.jl`](tui/bluesky_tui.jl))

A cassette-futurist, vintage-hardware Bluesky terminal UI built with
[`Tachikoma.jl`](https://github.com/Techno-Wizard/Tachikoma.jl) and `ATProto.jl`
(see the full step-by-step walkthrough in [`docs/src/tui_guide.md`](../docs/src/tui_guide.md)).
Each tab is housed in its own boxy retro CRT monitor / vintage workstation chassis with
thick polycarbonate bezels, cooling louvers (`≡≡≡`), recessed curved phosphor glass, subtle
raster scanlines (`v`), ambient rolling `DotWave` horizon waves (`b`), speaker grilles,
breathing power LEDs, and draggable split panes:

- **6 vintage-hardware tabs** (`1`–`6` or mouse click on connected rounded `BoxTabs`):
  - **`1 Feed`** — **`AT-5150`** floppy-bay PC unit (spacious 3-row post cards, animated phosphor rail, `[▬▬▬▬●▬▬▬▬]` drive LED, track counter `TRK 01/25`, bookmark flags `⚑`) paired with a **`PVM-14`** broadcast CRT monitor (RichText `Span`s with OSC-8 clickable links, framed embed cards, engagement pills, `◉ BRT / ◉ CNT` dials). Supports Follow/Unfollow (`F`), Mute (`M`), Quote-Post (`Q`), Bookmarks (`B`), Saved Feeds & Lists Switcher (`s`), and Image & Alt-Text Gallery (`i`). Drag the divider border with your mouse to resize panes!
  - **`2 Thread`** — **`VT-AT220`** terminal on a boxy CRT swivel pedestal showing parent context + focal post (`★ FOCAL`) + nested reply railway tree, with Reply (`p`), Quote-Post (`Q`), and Media Gallery (`i`).
  - **`3 Profile`** — **`IBM-3270`** identity workstation on a swivel CRT pedestal with stat capsules, bio facet highlighting, Follow/Unfollow (`F`), Mute (`M`), Avatar/Banner Media Inspector (`i`), and a double-bordered AT Protocol Identity Verification Certificate + illuminated `ID VERIFIED` chin lamp.
  - **`4 Notifs`** — **`DEC-LA120`** teletype pager with live unread count badge on the tab bar & header, reason chips (`LIKE`/`RPST`/`FLW`/`MNTN`/`RPLY`/`QUOT`), mark-all-seen (`m`), and direct jump to target threads/profiles (`Enter`).
  - **`5 Chat`** — **`TTY-DM300`** encrypted courier terminal routed over `atproto-proxy` (`did:web:api.bsky.chat#bsky_chat`) with a resizable Conversations list, live unread badges, message transcript (`TTY-MSG`), and DM composer (`c`).
  - **`6 Firehose`** — **`JS-MODEM`** carrier receiver + **`TEK-4010`** storage-tube oscilloscope (`Sparkline` events/sec) + **`TTY-LIVE`** live Jetstream WebSocket commit stream.
- **Modular architecture**: split cleanly into `state.jl`, `rendering.jl`, `actions.jl`, `tabs.jl`, `modals.jl`, and `events.jl` coordinated by `BlueskyTUI.jl`.
- **Floating drop-shadowed CRT dialogs & phosphor presets**:
  - Go-to-Actor (`g`, live `is_valid_handle`/`is_valid_did` validation), Search/Filter (`/`), Compose/Reply/Quote (`c`/`p`/`Q` with a live shimmering `Gauge` for the 300-grapheme budget & live facet chips), Saved Feeds/Lists/Bookmarks Switcher (`s`), Image & Alt-Text Gallery Inspector (`i`), DM Composer (`c` on Chat), masked App Password Login (`L`), Help (`?`).
  - Press **`P`** to quick-cycle authentic CRT phosphor presets (`esper` Amber CRT → `neuromancer` P31 Green → `kokaku` Cyber Blue → `outrun` Synthwave → `catppuccin` → `paper` Beige Terminal), **`v`** to toggle CRT scanlines, **`b`** to toggle the `DotWave` horizon, or **`Ctrl+T`** for all 25+ Tachikoma themes.

### Launch

```bash
# One-time setup of the isolated TUI environment
julia --project=examples/tui -e 'using Pkg; Pkg.instantiate()'

# Launch in warm Amber CRT phosphor mode (default: esper)
julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl --actor bsky.app

# Try P31 Green Phosphor CRT directly on the TEK-4010 Jetstream Firehose
julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl --tab firehose --theme neuromancer

# Optional: auto-sign in for Home Timeline, posting, replies, likes, and reposts
BSKY_HANDLE=you.bsky.social BSKY_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
  julia -t auto --project=examples/tui examples/tui/bluesky_tui.jl
```

### Headless Verification Suite

Run the mock-transport `Tachikoma.TestBackend` suite (no live network needed):

```bash
julia -t auto --project=examples/tui examples/tui/test_tui.jl
```

---

## 2. Bluesky Terminal CLI ([`bluesky_cli.jl`](bluesky_cli.jl))

Single-file CLI showcasing identity verification, public queries, lazy cursor pagination,
ANSI RichText rendering, live Jetstream filtering, and authenticated posting:

```bash
# Inspect an account (profile + bidirectional DID/handle verification)
julia --project=. examples/bluesky_cli.jl profile bsky.app

# Paginate recent posts with colored links, mentions & hashtags
julia --project=. examples/bluesky_cli.jl feed bsky.app --limit 5

# Inspect a post thread tree
julia --project=. examples/bluesky_cli.jl thread at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/...

# Stream live posts matching a keyword over Jetstream
julia --project=. examples/bluesky_cli.jl firehose --count 10 --filter julia

# Preview facet detection without publishing
julia --project=. examples/bluesky_cli.jl post "🚀 Hello @bsky.app https://julialang.org #JuliaLang" --dry-run

# Publish for real (use a Bluesky App Password, not your main password)
BSKY_HANDLE=you.bsky.social BSKY_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
  julia --project=. examples/bluesky_cli.jl post "Hello from ATProto.jl! #JuliaLang"
```

---

## 3. Live Jetstream Analytics Monitor ([`jetstream_monitor.jl`](jetstream_monitor.jl))

Connects to Bluesky's public Jetstream WebSocket firehose, measures live throughput,
counts events by collection/operation, tallies top hashtags, and prints the resume cursor:

```bash
julia --project=. examples/jetstream_monitor.jl --count 200 --seconds 10
```

---

## 4. RichText → HTML & Markdown Renderer ([`richtext_renderer.jl`](richtext_renderer.jl))

Builds a multi-byte UTF-8 rich text post with `RichTextDoc`, renders it to HTML and Markdown
via `segments`, and prints the exact AT Protocol wire JSON:

```bash
julia --project=. examples/richtext_renderer.jl
```
