using ATProto
using Aqua
using Test

@testset "Code quality (Aqua.jl)" begin
    Aqua.test_all(ATProto; deps_compat = (ignore = [:Base64, :Dates, :Unicode],))
end
