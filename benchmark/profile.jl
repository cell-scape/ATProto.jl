#!/usr/bin/env julia

# Automated CPU, Allocation & Invalidation profiling for ATProto.jl
#
# Usage:
#   julia --project=benchmark benchmark/profile.jl [output_dir]
#
# Produces:
#   - `<output_dir>/cpu.pb.gz`    (PProf CPU profile — view via `pprof -http=:8080 cpu.pb.gz`)
#   - `<output_dir>/allocs.pb.gz` (PProf heap allocation profile)
#   - Markdown summary printed to stdout (TimerOutputs table + invalidations count)

const _PKG_ROOT = normpath(joinpath(@__DIR__, ".."))
if !(_PKG_ROOT in LOAD_PATH)
    push!(LOAD_PATH, _PKG_ROOT)
end

using SnoopCompileCore
# Measure invalidations triggered by loading ATProto before importing anything else
const _INVALS = @snoop_invalidations begin
    using ATProto
end

using ATProto.API
using ATProto.Client
using ATProto.Jetstream
using ATProto.Syntax
using JSON
using PProf
using Printf
using Profile
using SnoopCompile
using TimerOutputs

const OUT_DIR = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "out")
mkpath(OUT_DIR)

const SAMPLE_DID = "did:plc:z72i7hdynmk6r22z27h6tvur"
const SAMPLE_DT = "2026-11-19T22:00:00.123456Z"
const SAMPLE_ATURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y"

const SAMPLE_FEED_JSON = JSON.json(Dict(
    "cursor" => "c1",
    "feed" => [
        Dict(
            "post" => Dict(
                "uri" => "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh$(lpad(i, 2, 'a'))",
                "cid" => "bafyrei$i",
                "author" => Dict("did" => SAMPLE_DID, "handle" => "bsky.app", "displayName" => "Bluesky"),
                "record" => Dict(
                    "\$type" => "app.bsky.feed.post",
                    "text" => "Feed post #$i with realistic text content.",
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

const SAMPLE_POST = API.App.Bsky.Feed.Post.Main(
    text = "Profiling ATProto.jl JSON serialization.",
    createdAt = SAMPLE_DT,
    langs = ["en"],
)

function run_workload!(to::TimerOutput; iters::Int = 200)
    @timeit to "syntax/validate_aturi (x1000)" begin
        ok = true
        for _ in 1:1000
            ok &= is_valid_aturi(SAMPLE_ATURI)
        end
        ok
    end
    @timeit to "syntax/parse_aturi (x500)" begin
        acc = 0
        for _ in 1:500
            u = parse(AtUri, SAMPLE_ATURI)
            acc += ncodeunits(u.authority.value)
        end
        acc
    end
    @timeit to "json/write_post (x500)" begin
        acc = 0
        for _ in 1:500
            acc += ncodeunits(JSON.json(SAMPLE_POST))
        end
        acc
    end
    @timeit to "jetstream/parse_commit (x500)" begin
        acc = Int64(0)
        for _ in 1:500
            ev = parse_jetstream_event(SAMPLE_JETSTREAM_COMMIT)
            acc += ev.time_us
        end
        acc
    end
    @timeit to "json/parse_feed_50 (x$(iters))" begin
        acc = 0
        for _ in 1:iters
            out = JSON.parse(SAMPLE_FEED_JSON, API.AppBskyFeedGetAuthorFeedOutput)
            acc += length(out.feed)
        end
        acc
    end
    return nothing
end

function main()
    # Warmup JIT before profiling
    warm_to = TimerOutput()
    run_workload!(warm_to; iters = 5)

    # 1. Phase breakdown via TimerOutputs
    to = TimerOutput()
    run_workload!(to; iters = 200)

    # 2. CPU profile -> PProf .pb.gz
    Profile.clear()
    cpu_to = TimerOutput()
    Profile.@profile run_workload!(cpu_to; iters = 300)
    cpu_out = joinpath(OUT_DIR, "cpu.pb.gz")
    PProf.pprof(; web = false, out = cpu_out)

    # 3. Heap allocation profile -> PProf .pb.gz
    Profile.Allocs.clear()
    alloc_to = TimerOutput()
    Profile.Allocs.@profile sample_rate = 0.05 run_workload!(alloc_to; iters = 50)
    alloc_out = joinpath(OUT_DIR, "allocs.pb.gz")
    PProf.Allocs.pprof(; web = false, out = alloc_out)

    # 4. Invalidation audit via SnoopCompile
    trees = SnoopCompile.invalidation_trees(_INVALS)
    n_invalidated = length(SnoopCompile.uinvalidated(_INVALS))

    println("### TimerOutputs Breakdown")
    println("```")
    show(stdout, to; allocations = true, sortby = :time)
    println("\n```")
    println()
    println("### Compilation Invalidation Audit (`SnoopCompile`)")
    println("- Method invalidation trees on `using ATProto`: **$(length(trees))** (unique invalidated MethodInstances: **$(n_invalidated)**)")
    println()
    println("### Generated PProf Artifacts")
    println("- CPU profile: `$(relpath(cpu_out))` ($(filesize(cpu_out)) bytes)")
    println("- Allocation profile: `$(relpath(alloc_out))` ($(filesize(alloc_out)) bytes)")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
