using Documenter
using ATProto

DocMeta.setdocmeta!(
    ATProto,
    :DocTestSetup,
    :(using ATProto, ATProto.Syntax, ATProto.Crypto, ATProto.DagCbor, ATProto.API, ATProto.Identity, ATProto.Repo, ATProto.Client, ATProto.RichText, ATProto.OAuth, ATProto.Jetstream);
    recursive = true,
)

makedocs(
    sitename = "ATProto.jl",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        edit_link = "main",
    ),
    modules = [
        ATProto,
        ATProto.Syntax,
        ATProto.Crypto,
        ATProto.DagCbor,
        ATProto.API,
        ATProto.PLC,
        ATProto.Identity,
        ATProto.Lexicon,
        ATProto.Repo,
        ATProto.Client,
        ATProto.RichText,
        ATProto.OAuth,
        ATProto.Jetstream,
    ],
    checkdocs = :exports,
    doctest = true,
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Tutorial" => "tutorial.md",
        "Building a Retro CRT TUI" => "tui_guide.md",
        "Reference" => [
            "Syntax Primitives" => "syntax.md",
            "Cryptography & CIDs" => "crypto.md",
            "DAG-CBOR Codec" => "dagcbor.md",
            "PLC & DID Resolution" => "plc.md",
            "Identity Resolution" => "identity.md",
            "Runtime Lexicon Validation" => "lexicon.md",
            "Repositories, MST & CAR" => "repo.md",
            "XRPC Client & Pagination" => "client.md",
            "RichText & Facets" => "richtext.md",
            "OAuth 2.1, DPoP & Service Auth" => "oauth.md",
            "Jetstream Streaming" => "jetstream.md",
            "Lexicon API & Codegen" => "api.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/cell-scape/ATProto.jl.git",
    devbranch = "main",
)
