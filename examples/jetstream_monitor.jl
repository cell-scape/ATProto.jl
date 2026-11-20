#!/usr/bin/env julia

#=
jetstream_monitor.jl — Real-time Bluesky Jetstream analytics & hashtag counter.

Demonstrates:
  - Multi-collection Jetstream subscription (`subscribe_jetstream`)
  - Extracting typed `AppBskyFeedPost` records & `AppBskyRichtextFacetTag` hashtags
  - Computing live throughput & printing the final cursor for lossless restart

Usage:
  julia --project=. examples/jetstream_monitor.jl [--count 200] [--seconds 10]
=#

using ATProto
using Printf

function parse_arg(args::Vector{String}, flag::String, default::Int)
    idx = findfirst(==(flag), args)
    isnothing(idx) && return default
    return parse(Int, args[idx + 1])
end

function run_monitor(; max_events::Int = 200, max_seconds::Real = 10.0)
    col_counts = Dict{String, Int}()
    op_counts = Dict{Symbol, Int}()
    tag_counts = Dict{String, Int}()
    total = 0
    t0 = time()
    deadline = t0 + max_seconds
    final_cursor = nothing

    collections = ["app.bsky.feed.post", "app.bsky.feed.like", "app.bsky.graph.follow"]
    println("Listening to Jetstream for up to $(max_events) events or $(max_seconds)s...")

    subscribe_jetstream(wanted_collections = collections, reconnect = true) do stream
        for ev in stream
            total += 1
            if ev isa JetstreamCommitEvent
                col = String(ev.collection)
                col_counts[col] = get(col_counts, col, 0) + 1
                op_counts[ev.operation] = get(op_counts, ev.operation, 0) + 1

                if ev.record isa API.AppBskyFeedPost && !isnothing(ev.record.facets)
                    for facet in ev.record.facets
                        for feat in facet.features
                            if feat isa API.AppBskyRichtextFacetTag
                                tag = lowercase(feat.tag)
                                tag_counts[tag] = get(tag_counts, tag, 0) + 1
                            end
                        end
                    end
                end
            end
            (total >= max_events || time() >= deadline) && break
        end
        final_cursor = last_cursor(stream)
    end

    elapsed = max(time() - t0, 1e-6)
    @printf("\nCollected %d events in %.2fs (%.1f events/s)\n", total, elapsed, total / elapsed)
    println("Resume cursor: ", final_cursor)

    println("\nBy collection:")
    for (col, n) in sort(collect(col_counts); by = last, rev = true)
        @printf("  %-26s %6d\n", col, n)
    end

    println("\nBy operation:")
    for (op, n) in sort(collect(op_counts); by = last, rev = true)
        @printf("  %-26s %6d\n", string(op), n)
    end

    if !isempty(tag_counts)
        println("\nTop hashtags:")
        for (tag, n) in first(sort(collect(tag_counts); by = last, rev = true), 10)
            @printf("  #%-25s %6d\n", tag, n)
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    max_events = parse_arg(ARGS, "--count", 200)
    max_seconds = parse_arg(ARGS, "--seconds", 10)
    run_monitor(; max_events, max_seconds)
end
