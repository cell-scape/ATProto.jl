using Documenter
using ATProto

DocMeta.setdocmeta!(
    ATProto,
    :DocTestSetup,
    :(using ATProto, ATProto.Syntax, ATProto.API, ATProto.Identity, ATProto.Client, ATProto.RichText, ATProto.Jetstream);
    recursive = true,
)

makedocs(
    sitename = "ATProto.jl",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        edit_link = "main",
    ),
    modules = [ATProto, ATProto.Syntax, ATProto.API, ATProto.Identity, ATProto.Client, ATProto.RichText, ATProto.Jetstream],
    checkdocs = :exports,
    doctest = true,
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Tutorial" => "tutorial.md",
        "Building a Retro CRT TUI" => "tui_guide.md",
        "Reference" => [
            "Syntax Primitives" => "syntax.md",
            "Identity Resolution" => "identity.md",
            "XRPC Client & Pagination" => "client.md",
            "RichText & Facets" => "richtext.md",
            "Jetstream Streaming" => "jetstream.md",
            "Lexicon API & Codegen" => "api.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/cell-scape/ATProto.jl.git",
    devbranch = "main",
    push_preview = true,
)
