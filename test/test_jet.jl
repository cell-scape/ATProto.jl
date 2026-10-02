using ATProto
using JET
using Test

!JET.JET_AVAILABLE && return

@testset "JET.jl" begin
    test_package(ATProto; 
                 broken = false,
                 skip = false,
                 toplevel_logger=nothing)
end
