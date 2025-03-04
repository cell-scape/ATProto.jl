const LEXICONS_PATH = relpath(joinpath(pkgdir(@__MODULE__), "lexicons"))

function get_lexicons(lexicon_path=LEXICONS_PATH; paths=String[])
    for path in readdir(lexicon_path; join=true)
        if isdir(path)
            _ = get_lexicons(path, paths=paths)
        elseif isfile(path) && endswith(lowercase(path), ".json")
            push!(paths, path)
        end
    end
    return paths
end

