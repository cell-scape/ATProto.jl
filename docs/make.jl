using ATProto
using Documenter

DocMeta.setdocmeta!(ATProto, :DocTestSetup, :(using ATProto); recursive = true)

makedocs(;
    modules = [ATProto],
    authors = "Bradley Dowling <brad.dowling@protonmail.com> and contributors",
    sitename = "ATProto.jl",
    format = Documenter.HTML(;
        canonical = "https://cell-scape.github.io/ATProto.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
    ],
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(;
    repo = "github.com/cell-scape/ATProto.jl",
    devbranch = "main",
)
