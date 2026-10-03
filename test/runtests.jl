using ATProto
using ParallelTestRunner
using Supposition
using Test

# Property-based suites run in this process (Supposition reports don't
# survive ParallelTestRunner's worker serialization); excluded below.
@testset "property tests" begin
    include("test_prop_codecs.jl")
    include("test_prop_mst.jl")
end

tests = find_tests(joinpath(pkgdir(ATProto), "test"))
for name in collect(keys(tests))
    startswith(name, "test_prop_") && delete!(tests, name)
end

runtests(ATProto, ARGS; testsuite = tests)
