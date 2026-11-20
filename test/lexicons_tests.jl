using ATProto
using Test

@testset "Lexicon discovery" begin
    path = lexicons_path()
    @test isdir(path)
    @test isabspath(path)

    files = get_lexicons()
    @test length(files) == 237
    @test all(f -> isfile(f) && endswith(f, ".json"), files)
    @test issorted(files)

    # Verify loading works regardless of current working directory
    mktempdir() do tmp
        cd(tmp) do
            @test get_lexicons() == files
        end
    end

    post_lex = first(filter(f -> endswith(f, joinpath("app", "bsky", "feed", "post.json")), files))
    doc = load_lexicon(post_lex)
    @test doc["id"] == "app.bsky.feed.post"
    @test doc["lexicon"] == 1
end
