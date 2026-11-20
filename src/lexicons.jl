"""
    lexicons_path() -> String

Return the absolute path to the bundled AT Protocol Lexicon schemas directory.
"""
function lexicons_path()
    root = pkgdir(@__MODULE__)
    isnothing(root) && error("Could not resolve package directory for ATProto")
    return joinpath(root, "lexicons")
end

"""
    get_lexicons(lexicon_path=lexicons_path()) -> Vector{String}

Recursively find and return sorted paths to all `.json` Lexicon schema files
under `lexicon_path`.
"""
function get_lexicons(lexicon_path::AbstractString=lexicons_path())
    paths = String[]
    for (root, _, files) in walkdir(lexicon_path)
        for file in files
            endswith(lowercase(file), ".json") && push!(paths, joinpath(root, file))
        end
    end
    sort!(paths)
    return paths
end

"""
    load_lexicon(path::AbstractString) -> Dict{String, Any}

Read and parse a single Lexicon JSON schema file from `path`.
"""
load_lexicon(path::AbstractString) = JSON.parsefile(path, Dict{String, Any})
