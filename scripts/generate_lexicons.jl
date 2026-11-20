#!/usr/bin/env julia

# Regenerate ATProto.jl Lexicon API types from the vendored `lexicons/` JSON schemas.
# Usage: julia --project=. scripts/generate_lexicons.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "..", "src", "codegen.jl"))

lexicons_dir = joinpath(@__DIR__, "..", "lexicons")
out_dir = joinpath(@__DIR__, "..", "src", "api", "generated")

stats = LexiconCodegen.generate_lexicons(lexicons_dir, out_dir)
println("Generated ATProto Lexicons into $(relpath(out_dir)):")
println("  Lexicon schemas : $(stats.lexicons)")
println("  Generated defs  : $(stats.types)")
println("  Cycle breaks    : $(stats.cycle_breaks)")
println("  Union members   : $(stats.union_members)")
