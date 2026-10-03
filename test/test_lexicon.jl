using Test
using ATProto
using ATProto.Lexicon
using ATProto.Crypto
using ATProto.DagCbor
using ATProto.XRPC: parse_lex
using JSON

# A small lexicon exercising most validator paths
const TEST_LEXICON = parse_lex("""
{
  "lexicon": 1,
  "id": "com.example.post",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "type": "object",
        "required": ["text", "createdAt"],
        "nullable": ["replyTo"],
        "properties": {
          "text": {"type": "string", "maxLength": 100, "minLength": 1, "maxGraphemes": 50},
          "createdAt": {"type": "string", "format": "datetime"},
          "replyTo": {"type": "ref", "ref": "com.example.post#replyRef"},
          "tags": {"type": "array", "items": {"type": "string"}, "maxLength": 8},
          "viaApp": {"type": "string", "default": "unknown"},
          "visibility": {"type": "string", "enum": ["public", "unlisted"]},
          "subject": {"type": "ref", "ref": "com.atproto.repo.strongRef"},
          "attachment": {"type": "blob"},
          "stats": {"type": "integer", "minimum": 0, "maximum": 1000},
          "pinned": {"type": "boolean"},
          "meta": {"type": "unknown"}
        }
      }
    },
    "replyRef": {
      "type": "object",
      "required": ["uri", "cid"],
      "properties": {
        "uri": {"type": "string", "format": "at-uri"},
        "cid": {"type": "string", "format": "cid"}
      }
    }
  }
}
""")

const STRONG_REF_LEXICON = parse_lex("""
{
  "lexicon": 1,
  "id": "com.atproto.repo.strongRef",
  "defs": {
    "main": {
      "type": "object",
      "required": ["uri", "cid"],
      "properties": {
        "uri": {"type": "string", "format": "at-uri"},
        "cid": {"type": "string", "format": "cid"}
      }
    }
  }
}
""")

const lexicons = let l = Lexicons()
    add_lexicon!(l, TEST_LEXICON)
    add_lexicon!(l, STRONG_REF_LEXICON)
    l
end
const main_def = get_def_or_throw(lexicons, "com.example.post")

@testset "lexicon doc parsing" begin
    @test parse_lexicon_doc(TEST_LEXICON)["id"] == "com.example.post"
    @test_throws InvalidLexiconError parse_lexicon_doc(Dict("lexicon" => 2, "id" => "a.b.c", "defs" => Dict()))
    @test_throws InvalidLexiconError parse_lexicon_doc(Dict("lexicon" => 1, "id" => "not-an-nsid", "defs" => Dict("main" => Dict("type" => "token"))))
    @test_throws InvalidLexiconError parse_lexicon_doc(Dict("lexicon" => 1, "id" => "a.b.c", "defs" => Dict()))
    # record definitions must be at main
    bad = Dict("lexicon" => 1, "id" => "a.b.c",
               "defs" => Dict("main" => Dict("type" => "token"),
                              "other" => Dict("type" => "record", "record" => Dict("type" => "object"))))
    @test_throws InvalidLexiconError parse_lexicon_doc(bad)
    # unknown def type
    bad2 = Dict("lexicon" => 1, "id" => "a.b.c",
                "defs" => Dict("main" => Dict("type" => "warp")))
    @test_throws InvalidLexiconError parse_lexicon_doc(bad2)
end

@testset "Lexicons resolution" begin
    @test to_lex_uri("com.example.post") == "com.example.post#main"
    @test to_lex_uri("com.example.post#replyRef") == "com.example.post#replyRef"
    @test get_def(lexicons, "com.example.post")["type"] == "record"
    @test get_def(lexicons, "com.example.post#replyRef")["type"] == "object"
    @test get_def(lexicons, "com.missing.thing") === nothing
    @test_throws LexiconDefNotFoundError get_def_or_throw(lexicons, "com.missing.thing")
end

@testset "record validation" begin
    cid = cid_for_dagcbor("post")
    good = Dict{String,Any}(
        "text" => "hello world",
        "createdAt" => "2023-06-01T12:00:00.000Z",
        "stats" => 5,
        "pinned" => true,
        "meta" => Dict("anything" => "goes"),
        "subject" => Dict("\$type" => "com.atproto.repo.strongRef",
                          "uri" => "at://did:plc:abc/com.example.post/3jzfcijpj2z2a",
                          "cid" => string(cid)),
        "attachment" => BlobRef(cid, "image/png", 1000),
        "replyTo" => nothing,  # nullable
    )
    validated = assert_valid_record(lexicons, main_def, good)
    @test validated["text"] == "hello world"
    @test validated["viaApp"] == "unknown"  # default applied

    # required missing
    bad1 = Dict{String,Any}("text" => "hi")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad1)

    # format violation
    bad2 = Dict{String,Any}("text" => "hi", "createdAt" => "yesterday")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad2)

    # maxLength (utf-8 bytes)
    bad3 = Dict{String,Any}("text" => "x"^101, "createdAt" => "2023-06-01T12:00:00Z")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad3)
    # 50 single-byte chars OK (50 bytes, 50 graphemes)
    ok3 = Dict{String,Any}("text" => "x"^50, "createdAt" => "2023-06-01T12:00:00Z")
    @test assert_valid_record(lexicons, main_def, ok3)["text"] == "x"^50

    # bytes-only violation: 26 emoji = 104 bytes > maxLength 100, but 26 <= 50 graphemes
    bad4 = Dict{String,Any}("text" => "🎉"^26, "createdAt" => "2023-06-01T12:00:00Z")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad4)
    # 12 emoji = 48 bytes and 12 graphemes: OK
    ok4 = Dict{String,Any}("text" => "🎉"^12, "createdAt" => "2023-06-01T12:00:00Z")
    @test assert_valid_record(lexicons, main_def, ok4)["text"] == "🎉"^12

    # graphemes: 51 ASCII chars = 51 graphemes > 50 (bytes OK at 51 <= 100)
    bad5 = Dict{String,Any}("text" => "y"^51, "createdAt" => "2023-06-01T12:00:00Z")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad5)

    # integer bounds
    bad6 = Dict{String,Any}("text" => "hi", "createdAt" => "2023-06-01T12:00:00Z", "stats" => 1001)
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad6)

    # enum
    bad7 = Dict{String,Any}("text" => "hi", "createdAt" => "2023-06-01T12:00:00Z", "visibility" => "secret")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad7)
    ok7 = Dict{String,Any}("text" => "hi", "createdAt" => "2023-06-01T12:00:00Z", "visibility" => "public")
    @test assert_valid_record(lexicons, main_def, ok7)["visibility"] == "public"

    # ref validation recurses into strongRef: bad at-uri
    bad8 = Dict{String,Any}("text" => "hi", "createdAt" => "2023-06-01T12:00:00Z",
                            "subject" => Dict("\$type" => "com.atproto.repo.strongRef",
                                              "uri" => "not a uri", "cid" => string(cid)))
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad8)

    # blob must be a BlobRef
    bad9 = Dict{String,Any}("text" => "hi", "createdAt" => "2023-06-01T12:00:00Z",
                            "attachment" => "not a blob")
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad9)

    # arrays with maxLength
    bad10 = Dict{String,Any}("text" => "hi", "createdAt" => "2023-06-01T12:00:00Z",
                             "tags" => String[] )
    for i in 1:9; push!(bad10["tags"], "t$i"); end
    @test_throws LexiconValidationError assert_valid_record(lexicons, main_def, bad10)
end

@testset "string formats" begin
    def(fmt) = Dict{String,Any}("type" => "string", "format" => fmt)
    ok, v, err = validate_lex_ref_variant(lexicons, "s", def("did"), "did:plc:ewvi7nx4oun5hl7s6yqkgcto")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("did"), "did:plc:bad!")
    @test !ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("at-uri"),
                                          "at://did:plc:abc/com.example.post/3jzfcijpj2z2a")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("nsid"), "app.bsky.feed.post")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("language"), "en-US")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("tid"), "3jzfcijpj2z2a")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("record-key"), "self")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("cid"), "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("uri"), "https://example.com/x?y=1")
    @test ok
    ok, _, err = validate_lex_ref_variant(lexicons, "s", def("uri"), "not a uri")
    @test !ok
end

@testset "unions" begin
    union_def = Dict{String,Any}("type" => "union",
                                 "refs" => ["com.atproto.repo.strongRef"])
    val = Dict("\$type" => "com.atproto.repo.strongRef",
               "uri" => "at://did:plc:abc/x/1", "cid" => string(cid_for_dagcbor("x")))
    ok, v, err = validate_lex_ref_variant(lexicons, "u", union_def, val)
    @test ok

    # open union: unlisted $type passes through unvalidated
    other = Dict("\$type" => "com.example.other", "whatever" => 1)
    ok, v, err = validate_lex_ref_variant(lexicons, "u", union_def, other)
    @test ok && v == other

    # closed union: unlisted $type rejected
    closed_def = Dict{String,Any}("type" => "union", "closed" => true,
                                  "refs" => ["com.atproto.repo.strongRef"])
    ok, _, err = validate_lex_ref_variant(lexicons, "u", closed_def, other)
    @test !ok

    # missing $type
    ok, _, err = validate_lex_ref_variant(lexicons, "u", union_def, Dict("a" => 1))
    @test !ok

    # implicit #main matching
    refs_both = Dict{String,Any}("type" => "union", "closed" => true,
                                 "refs" => ["com.atproto.repo.strongRef#main"])
    ok, _, err = validate_lex_ref_variant(lexicons, "u", refs_both, val)
    @test ok  # $type "com.atproto.repo.strongRef" matches the "#main" ref
end

@testset "xrpc params validation" begin
    qdef = parse_lex("""
    {"lexicon": 1, "id": "com.example.search",
     "defs": {"main": {"type": "query",
       "parameters": {"type": "params", "required": ["q"],
         "properties": {
           "q": {"type": "string", "minLength": 1},
           "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 25},
           "strict": {"type": "boolean", "default": false}
         }}}}}""")
    add_lexicon!(lexicons, qdef)
    d = get_def(lexicons, "com.example.search")

    params = assert_valid_xrpc_params(lexicons, d, Dict{String,Any}("q" => "hello"))
    @test params["q"] == "hello"
    @test params["limit"] == 25      # default
    @test params["strict"] == false  # default

    # missing required
    @test_throws LexiconValidationError assert_valid_xrpc_params(lexicons, d, Dict{String,Any}())
    # out of range
    @test_throws LexiconValidationError assert_valid_xrpc_params(lexicons, d,
        Dict{String,Any}("q" => "x", "limit" => 500))
    # non-object params treated as empty -> required error
    @test_throws LexiconValidationError assert_valid_xrpc_params(lexicons, d, nothing)
end

@testset "BlobRef" begin
    cid = cid_for_dagcbor("blobdata")
    br = BlobRef(cid, "image/jpeg", 2048)
    @test br.ref == cid
    @test br.mime_type == "image/jpeg"
    @test br.size == 2048

    # typed JSON round trip
    json_form = blob_ref_to_json(br)
    parsed = blob_ref_from_json(json_form)
    @test parsed == br
    @test parsed.original["\$type"] == "blob"

    # legacy JSON
    legacy = Dict{String,Any}("cid" => string(cid), "mimeType" => "image/png")
    parsed2 = blob_ref_from_json(legacy)
    @test parsed2 !== nothing
    @test parsed2.ref == cid
    @test parsed2.mime_type == "image/png"
    @test parsed2.size == -1

    # ipld form (DAG-CBOR): empty-string CID key
    ipld = blob_ref_to_ipld(br)
    @test ipld[""] == cid
    decoded = blob_ref_from_ipld(dag_cbor_decode(dag_cbor_encode(ipld)))
    @test decoded == br

    # non-blobrefs
    @test blob_ref_from_json(Dict{String,Any}("x" => 1)) === nothing
    @test blob_ref_from_json(Dict{String,Any}("\$type" => "blob", "mimeType" => "x")) === nothing
end


function _collect_refs!(missing, lexicons::Lexicons, nsid, def)
    def isa AbstractDict || return
    for (k, v) in def
        if k == "ref" && v isa AbstractString && get_def(lexicons, v) === nothing
            push!(missing, "$nsid -> $v")
        elseif k == "refs" && v isa AbstractVector
            for r in v
                if r isa AbstractString && get_def(lexicons, r) === nothing
                    push!(missing, "$nsid -> $r")
                end
            end
        elseif v isa AbstractDict
            _collect_refs!(missing, lexicons, nsid, v)
        end
    end
end

@testset "official lexicons parse" begin
    lexdir = joinpath(@__DIR__, "..", "docs", "reference", "atproto", "lexicons")
    isdir(lexdir) && begin
        official = Lexicons()
        count = 0
        for (root, _, files) in walkdir(lexdir)
            for f in files
                endswith(f, ".json") || continue
                doc = JSON.parsefile(joinpath(root, f))
                add_lexicon!(official, doc)
                count += 1
            end
        end
        @test count > 300  # the official schema corpus
        # every def reference across all documents resolves
        missing_refs = String[]
        for (nsid, doc) in official.docs
            for (def_id, def) in doc["defs"]
                _collect_refs!(missing_refs, official, nsid, def)
            end
        end
        @test isempty(missing_refs)
        # spot check a well-known def
        post = get_def(official, "app.bsky.feed.post")
        @test post["type"] == "record"
        @test "text" in post["record"]["required"]
    end
end
