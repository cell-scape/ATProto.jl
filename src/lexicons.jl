const LEXICONS_PATH = joinpath(@__DIR__, "lexicons")

function get_lexicons(lexicon_path)
    paths = []
    for path in readdir(lexicon_path; join=true)
        lex_path = if isdir(path)
            get_lexicons(path)
        elseif isfile(path) && endswith(lowercase(path), ".json")
            path
        end
        push!(paths, lex_path)
    end
    return paths
end