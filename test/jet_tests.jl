using ATProto
using ATProto.API
using ATProto.Client
using ATProto.Identity
using ATProto.RichText
using ATProto.Syntax
using Dates
using JET
using Test

@testset "Static analysis (JET.jl)" begin
    @testset "Package error analysis" begin
        JET.test_package(ATProto; target_modules = (ATProto,))
    end

    @testset "Hot-path type stability (@test_opt)" begin
        @test_opt target_modules = (ATProto,) is_valid_handle("jay.bsky.social")
        @test_opt target_modules = (ATProto,) is_valid_did("did:plc:z72i7hdynmk6r22z27h6tvur")
        @test_opt target_modules = (ATProto,) is_valid_nsid("app.bsky.feed.post")
        @test_opt target_modules = (ATProto,) is_valid_record_key("3jui7kd54zh2y")
        @test_opt target_modules = (ATProto,) is_valid_tid("3jui7kd54zh2y")
        @test_opt target_modules = (ATProto,) is_valid_datetime("2026-11-19T22:00:00.123456Z")
        @test_opt target_modules = (ATProto,) is_valid_aturi("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y")

        @test_opt target_modules = (ATProto,) tryparse(Handle, "jay.bsky.social")
        @test_opt target_modules = (ATProto,) tryparse(DID, "did:plc:z72i7hdynmk6r22z27h6tvur")
        @test_opt target_modules = (ATProto,) tryparse(NSID, "app.bsky.feed.post")
        @test_opt target_modules = (ATProto,) tryparse(RecordKey, "3jui7kd54zh2y")
        @test_opt target_modules = (ATProto,) tryparse(TID, "3jui7kd54zh2y")
        @test_opt target_modules = (ATProto,) tryparse(ATDateTime, "2026-11-19T22:00:00.123456Z")
        @test_opt target_modules = (ATProto,) tryparse(AtUri, "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3jui7kd54zh2y")

        @test_opt target_modules = (ATProto,) next_tid()
        @test_opt target_modules = (ATProto,) tid_timestamp_us(tid"3jui7kd54zh2y")
        @test_opt target_modules = (ATProto,) tid_clockid(tid"3jui7kd54zh2y")
        @test_opt target_modules = (ATProto,) Dates.DateTime(ATDateTime("2026-11-19T22:00:00Z"))

        params = API.App.Bsky.Actor.GetProfiles.Params(actors = ["bsky.app"])
        @test_opt target_modules = (ATProto,) Client._encode_query_params(params)

        @test_opt target_modules = (ATProto,) detect_mentions("Hey @bsky.app!")
        @test_opt target_modules = (ATProto,) detect_links("See https://julialang.org")
        @test_opt target_modules = (ATProto,) detect_tags("Love #JuliaLang")
        @test_opt target_modules = (ATProto,) detect_facets("See https://julialang.org #JuliaLang")
        @test_opt target_modules = (ATProto,) segments(richtext("See https://julialang.org #JuliaLang"))
        @test_opt target_modules = (ATProto,) did_web_url(did"did:web:example.com")
    end
end
