module Lexicon

using ..Syntax
using ..Crypto
using ..DagCbor
using URIs
using JSON

export LexiconValidationError,
    InvalidLexiconError,
    LexiconDefNotFoundError,
    Lexicons,
    add_lexicon!,
    get_def,
    get_def_or_throw,
    parse_lexicon_doc,
    to_lex_uri,
    validate_lex_ref_variant,
    assert_valid_record,
    assert_valid_xrpc_params,
    assert_valid_xrpc_input,
    assert_valid_xrpc_output,
    BlobRef,
    blob_ref_from_json,
    blob_ref_to_json,
    blob_ref_from_ipld,
    blob_ref_to_ipld

include("errors.jl")
include("blobref.jl")
include("docs.jl")
include("validators.jl")

end # module
