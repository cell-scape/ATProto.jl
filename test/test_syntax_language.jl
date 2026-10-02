using Test
using ATProto
using ATProto.Syntax

@testset "Language" begin
    @testset "well-formed (lenient regex)" begin
        for s in (
            "en",
            "en-GB",
            "zh-Hans",
            "sr-Cyrl-RS",
            "hy-Latn-IT-arevela",
            "de-CH-1901",
            "en-a-aaa",
            "i-klingon",          # grandfathered (irregular)
            "en-GB-oed",          # grandfathered (regular)
            "x-private",          # private use only
            "JA",                 # legacy upper-case: well-formed, not strict
            "jaja",               # 4-letter: well-formed, not strict
        )
            @test is_valid_language(s)
        end
    end

    @testset "not well-formed" begin
        for s in ("", "en-", "-en", "123", "e", "toolonglanguagetag",
                  "en--US", "en-US-", "en US")
            @test !is_valid_language(s)
        end
    end

    @testset "strict parse" begin
        tag = parse_language("en-US")
        @test tag.language == "en"
        @test tag.region == "US"
        @test tag.script === nothing

        tag2 = parse_language("sr-Cyrl-RS")
        @test tag2.language == "sr"
        @test tag2.script == "Cyrl"
        @test tag2.region == "RS"

        tag3 = parse_language("hy-Latn-IT-arevela")
        @test tag3.variant == "arevela"

        tag4 = parse_language("de-CH-1901")
        @test tag4.region == "CH"
        @test tag4.variant == "1901"

        tag5 = parse_language("en-x-private")
        @test tag5.privateUse == "x-private"

        @test parse_language("i-klingon").grandfathered == "i-klingon"

        # strict rules: upper-case primary subtag and 4-letter primaries fail
        @test parse_language("JA") === nothing
        @test parse_language("jaja") === nothing
        # repeated variant subtag (case-insensitive) is rejected
        @test parse_language("de-CH-1901-1901") === nothing
        # repeated extension singleton is rejected
        @test parse_language("en-a-bbb-a-ccc") === nothing
        # but distinct singletons are fine
        @test parse_language("en-a-bbb-b-ccc") !== nothing
        # malformed
        @test parse_language("") === nothing
        @test parse_language("123") === nothing
    end
end
