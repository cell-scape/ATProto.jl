using ATProto
using ParallelTestRunner

const _PKG_ROOT = dirname(@__DIR__)

const init_worker_code = quote
    if !($(_PKG_ROOT) in LOAD_PATH)
        push!(LOAD_PATH, $(_PKG_ROOT))
    end
end

const init_code = quote
    using ATProto
    using ATProto.Syntax
    using ATProto.API
    using ATProto.Identity
    using ATProto.Client
    using ATProto.RichText
    using ATProto.Jetstream
    using Test
end

args = parse_args(ARGS)
testsuite = find_tests(@__DIR__)
runtests(ATProto, args; testsuite, init_worker_code, init_code)
