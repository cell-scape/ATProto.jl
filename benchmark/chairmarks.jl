#!/usr/bin/env julia

# Fast interactive / CLI microbenchmarks using Chairmarks.jl
# Usage:
#   julia --project=benchmark benchmark/chairmarks.jl

const _PKG_ROOT = normpath(joinpath(@__DIR__, ".."))
if !(_PKG_ROOT in LOAD_PATH)
    push!(LOAD_PATH, _PKG_ROOT)
end

using ATProto
using ATProto.API
using ATProto.Client
using ATProto.Jetstream
using ATProto.Syntax
using Chairmarks
using JSON
using Printf

const SAMPLE_HANDLE = "jay.bsky.social"
const SAMPLE_DID = "did:plc:z72i7hdynmk6r22z27h6tvur"
const SAMPLE_NSID = "app.bsky.feed.getAuthorFeed"
const SAMPLE_RKEY = "3jui7kd54zh2y"
const SAMPLE_TID = "3jui7kd54zh2y"
const SAMPLE_DT = "2026-11-19T22:00:00.123456Z"
const SAMPLE_ATURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"

const SAMPLE_POST = API.App.Bsky.Feed.Post.Main(
    text = "Hello Bluesky from ATProto.jl! Benchmarking JSON serialization and parsing.",
    createdAt = SAMPLE_DT,
    langs = ["en"],
    embed = API.App.Bsky.Embed.Images.Main(images = [
        API.App.Bsky.Embed.Images.Image(
            image = BlobRef(
                ref = CIDLink("bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
                mimeType = "image/png",
                size = 42000,
            ),
            alt = "Julia logo",
            aspectRatio = API.App.Bsky.Embed.Defs.AspectRatio(width = 800, height = 600),
        ),
    ]),
)
const SAMPLE_POST_JSON = JSON.json(SAMPLE_POST)

const SAMPLE_FEED_JSON = JSON.json(Dict(
    "cursor" => "2026-11-19T22:00:00.000Z",
    "feed" => [
        Dict(
            "post" => Dict(
                "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh$(lpad(i, 2, 'a'))",
                "cid" => "bafyrei$i",
                "author" => Dict("did" => SAMPLE_DID, "handle" => "bsky.app", "displayName" => "Bluesky"),
                "record" => Dict(
                    "\$type" => "app.bsky.feed.post",
                    "text" => "Feed post number $i with realistic text content.",
                    "createdAt" => SAMPLE_DT,
                    "langs" => ["en"],
                ),
                "indexedAt" => SAMPLE_DT,
            ),
        )
        for i in 1:50
    ],
))

const SAMPLE_JETSTREAM_COMMIT = JSON.json(Dict(
    "did" => SAMPLE_DID,
    "time_us" => 1725911162329308,
    "kind" => "commit",
    "commit" => Dict(
        "rev" => "3l3qo2vutsw2b",
        "operation" => "create",
        "collection" => "app.bsky.feed.post",
        "rkey" => "3l3qo2vuowo2b",
        "cid" => "bafyreid123",
        "record" => Dict(
            "\$type" => "app.bsky.feed.post",
            "createdAt" => SAMPLE_DT,
            "text" => "hello jetstream firehose!",
            "langs" => ["en"],
        ),
    ),
))

const SAMPLE_JETSTREAM_DELETE = JSON.json(Dict(
    "did" => SAMPLE_DID,
    "time_us" => 1725911162329400,
    "kind" => "commit",
    "commit" => Dict(
        "rev" => "3l3qo2vutsw2c",
        "operation" => "delete",
        "collection" => "app.bsky.feed.like",
        "rkey" => "3l3qo2vuowo2c",
    ),
))

const SAMPLE_PARAMS = API.App.Bsky.Actor.GetProfiles.Params(
    actors = ["bsky.app", SAMPLE_DID, "atproto.com"],
)
const SAMPLE_RICHTEXT = "🚀 Hey @bsky.app, check out https://julialang.org/docs and #JuliaLang #atproto!"
const SAMPLE_RTDOC = richtext(SAMPLE_RICHTEXT)

function _fmt_time(sec::Float64)
    sec < 1e-6 && return @sprintf("%7.1f ns", sec * 1e9)
    sec < 1e-3 && return @sprintf("%7.2f μs", sec * 1e6)
    return @sprintf("%7.2f ms", sec * 1e3)
end

function run_chairmarks()
    benches = [
        ("syntax/validate/handle",      () -> @b is_valid_handle($SAMPLE_HANDLE)),
        ("syntax/validate/did",         () -> @b is_valid_did($SAMPLE_DID)),
        ("syntax/validate/nsid",        () -> @b is_valid_nsid($SAMPLE_NSID)),
        ("syntax/validate/record_key",  () -> @b is_valid_record_key($SAMPLE_RKEY)),
        ("syntax/validate/tid",         () -> @b is_valid_tid($SAMPLE_TID)),
        ("syntax/validate/datetime",    () -> @b is_valid_datetime($SAMPLE_DT)),
        ("syntax/validate/aturi",       () -> @b is_valid_aturi($SAMPLE_ATURI)),
        ("syntax/parse/aturi",          () -> @b parse(AtUri, $SAMPLE_ATURI)),
        ("syntax/next_tid",             () -> @b next_tid()),
        ("json/write_post",             () -> @b JSON.json($SAMPLE_POST)),
        ("json/parse_post",             () -> @b JSON.parse($SAMPLE_POST_JSON, API.AppBskyFeedPost)),
        ("json/parse_post_union",       () -> @b JSON.parse($SAMPLE_POST_JSON, LexiconObject)),
        ("json/parse_feed_50",          () -> @b JSON.parse($SAMPLE_FEED_JSON, API.AppBskyFeedGetAuthorFeedOutput)),
        ("jetstream/commit_post",       () -> @b parse_jetstream_event($SAMPLE_JETSTREAM_COMMIT)),
        ("jetstream/commit_delete",     () -> @b parse_jetstream_event($SAMPLE_JETSTREAM_DELETE)),
        ("client/encode_query_params",  () -> @b Client._encode_query_params($SAMPLE_PARAMS)),
        ("richtext/detect_facets",      () -> @b detect_facets($SAMPLE_RICHTEXT)),
        ("richtext/segments",           () -> @b segments($SAMPLE_RTDOC)),
    ]

    println("| Benchmark | Min Time | Allocs | Bytes | Throughput |")
    println("|:----------|---------:|-------:|------:|-----------:|")
    rows = NamedTuple[]
    for (label, fn) in benches
        res = fn()
        rate = round(Int, 1.0 / res.time)
        @printf("| %-28s | %s | %6d | %8d B | %10d/s |\n",
                label, _fmt_time(res.time), round(Int, res.allocs), round(Int, res.bytes), rate)
        push!(rows, (label = label, time_s = res.time, allocs = res.allocs, bytes = res.bytes, rate = rate))
    end
    return rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_chairmarks()
end
