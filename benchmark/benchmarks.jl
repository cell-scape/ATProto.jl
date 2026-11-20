# PkgBenchmark.jl suite for ATProto.jl
#
# Run locally:
#   julia --project=benchmark -e 'using PkgBenchmark; results = benchmarkpkg(pwd()); println(export_markdown(results))'
#
# Compare against another branch/commit:
#   julia --project=benchmark -e 'using PkgBenchmark; j = judge(pwd(), "main"); println(export_markdown(j))'

using ATProto
using ATProto.API
using ATProto.Client
using ATProto.Jetstream
using ATProto.Syntax
using BenchmarkTools
using JSON

const SUITE = BenchmarkGroup()

# -----------------------------------------------------------------------------
# Sample payloads
# -----------------------------------------------------------------------------
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

const SAMPLE_JETSTREAM_IDENTITY = JSON.json(Dict(
    "did" => SAMPLE_DID,
    "time_us" => 1725911162329500,
    "kind" => "identity",
    "identity" => Dict(
        "did" => SAMPLE_DID,
        "handle" => "bsky.app",
        "seq" => 1409752997,
        "time" => SAMPLE_DT,
    ),
))

const SAMPLE_PARAMS = API.App.Bsky.Actor.GetProfiles.Params(
    actors = ["bsky.app", SAMPLE_DID, "atproto.com"],
)

# -----------------------------------------------------------------------------
# Syntax benchmarks
# -----------------------------------------------------------------------------
SUITE["syntax"] = BenchmarkGroup()
SUITE["syntax"]["validate"] = BenchmarkGroup()
SUITE["syntax"]["validate"]["handle"] = @benchmarkable is_valid_handle($SAMPLE_HANDLE)
SUITE["syntax"]["validate"]["did"] = @benchmarkable is_valid_did($SAMPLE_DID)
SUITE["syntax"]["validate"]["nsid"] = @benchmarkable is_valid_nsid($SAMPLE_NSID)
SUITE["syntax"]["validate"]["record_key"] = @benchmarkable is_valid_record_key($SAMPLE_RKEY)
SUITE["syntax"]["validate"]["tid"] = @benchmarkable is_valid_tid($SAMPLE_TID)
SUITE["syntax"]["validate"]["datetime"] = @benchmarkable is_valid_datetime($SAMPLE_DT)
SUITE["syntax"]["validate"]["aturi"] = @benchmarkable is_valid_aturi($SAMPLE_ATURI)

SUITE["syntax"]["parse"] = BenchmarkGroup()
SUITE["syntax"]["parse"]["handle"] = @benchmarkable parse(Handle, $SAMPLE_HANDLE)
SUITE["syntax"]["parse"]["did"] = @benchmarkable parse(DID, $SAMPLE_DID)
SUITE["syntax"]["parse"]["nsid"] = @benchmarkable parse(NSID, $SAMPLE_NSID)
SUITE["syntax"]["parse"]["aturi"] = @benchmarkable parse(AtUri, $SAMPLE_ATURI)
SUITE["syntax"]["parse"]["next_tid"] = @benchmarkable next_tid()

# -----------------------------------------------------------------------------
# JSON / Generated Lexicon API benchmarks
# -----------------------------------------------------------------------------
SUITE["json"] = BenchmarkGroup()
SUITE["json"]["write_post"] = @benchmarkable JSON.json($SAMPLE_POST)
SUITE["json"]["parse_post"] = @benchmarkable JSON.parse($SAMPLE_POST_JSON, API.AppBskyFeedPost)
SUITE["json"]["parse_post_union"] = @benchmarkable JSON.parse($SAMPLE_POST_JSON, LexiconObject)
SUITE["json"]["parse_feed_50"] = @benchmarkable JSON.parse($SAMPLE_FEED_JSON, API.AppBskyFeedGetAuthorFeedOutput)

# -----------------------------------------------------------------------------
# Jetstream firehose parsing benchmarks
# -----------------------------------------------------------------------------
SUITE["jetstream"] = BenchmarkGroup()
SUITE["jetstream"]["commit_post_create"] = @benchmarkable parse_jetstream_event($SAMPLE_JETSTREAM_COMMIT)
SUITE["jetstream"]["commit_like_delete"] = @benchmarkable parse_jetstream_event($SAMPLE_JETSTREAM_DELETE)
SUITE["jetstream"]["identity"] = @benchmarkable parse_jetstream_event($SAMPLE_JETSTREAM_IDENTITY)

# -----------------------------------------------------------------------------
# Client & RichText benchmarks
# -----------------------------------------------------------------------------
const SAMPLE_RICHTEXT = "🚀 Hey @bsky.app, check out https://julialang.org/docs and #JuliaLang #atproto!"

SUITE["client"] = BenchmarkGroup()
SUITE["client"]["encode_query_params"] = @benchmarkable Client._encode_query_params($SAMPLE_PARAMS)

SUITE["richtext"] = BenchmarkGroup()
SUITE["richtext"]["detect_facets"] = @benchmarkable detect_facets($SAMPLE_RICHTEXT)
SUITE["richtext"]["segments"] = @benchmarkable segments($(richtext(SAMPLE_RICHTEXT)))
