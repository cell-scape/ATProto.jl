using ATProto
using JET
using Test

!JET.JET_AVAILABLE && return

@testset "JET.jl" begin
    test_package(ATProto;
                 broken = false,
                 skip = false,
                 target_modules = (:ATProto,),
                 toplevel_logger=nothing)
end
