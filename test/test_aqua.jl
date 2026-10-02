using Aqua
using ATProto
using Test

@testset "Aqua.jl" begin
    Aqua.test_all(
                  ATProto;
                  ambiguities=(exclude=[], broken=false),
                  stale_deps=(ignore=Symbol[],),
                  deps_compat=(ignore=Symbol[],),
                  piracies=false,
                 )
end
