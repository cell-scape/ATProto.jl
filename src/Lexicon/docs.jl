# Lexicon documents and the cross-document definition resolver.
# Port of `packages/lexicon/src/{types,lexicons,util}.ts`.
#
# Definitions are kept as parsed JSON Dicts (exactly what the validators
# consume), with structure validated at `parse_lexicon_doc` time.

const MAIN_DEF_TYPES = ("record", "permission-set", "procedure", "query", "subscription")
const USER_DEF_TYPES = (MAIN_DEF_TYPES..., "blob", "array", "token", "object",
                        "boolean", "integer", "string", "bytes", "cid-link", "unknown")

"""
    to_lex_uri(ref) -> String

Normalize a definition reference: `"nsid"` becomes `"nsid#main"`.
"""
function to_lex_uri(ref::AbstractString)::String
    return occursin("#", ref) ? String(ref) : string(ref, "#main")
end

"""
    parse_lexicon_doc(doc) -> Dict

Validate the structure of a lexicon document (as a parsed JSON Dict):
`lexicon == 1`, a valid NSID `id`, a `defs` record of typed definitions, and
the rule that record/query/procedure/subscription/permission-set definitions
must live at `main`. Throws `InvalidLexiconError` on violations.
"""
function parse_lexicon_doc(doc::AbstractDict)::Dict{String,Any}
    get(doc, "lexicon", nothing) == 1 ||
        throw(InvalidLexiconError("Invalid lexicon version"))
    id = get(doc, "id", nothing)
    id isa AbstractString && is_valid_nsid(String(id)) ||
        throw(InvalidLexiconError("Lexicon id must be a valid NSID"))
    defs = get(doc, "defs", nothing)
    defs isa AbstractDict && !isempty(defs) ||
        throw(InvalidLexiconError("Lexicon must have a defs object"))

    for (def_id, def) in defs
        def isa AbstractDict ||
            throw(InvalidLexiconError("Definition $def_id must be an object"))
        dtype = get(def, "type", nothing)
        dtype isa AbstractString ||
            throw(InvalidLexiconError("Definition $def_id must have a type"))
        dtype in USER_DEF_TYPES ||
            throw(InvalidLexiconError("Invalid type: $dtype must be one of: " *
                                      join(USER_DEF_TYPES, ", ")))
        def_id != "main" && dtype in MAIN_DEF_TYPES &&
            throw(InvalidLexiconError("Records, permission sets, procedures, queries, and subscriptions must be the main definition."))
        _validate_def_shape(String(def_id), String(dtype), def)
    end
    return Dict{String,Any}(doc)
end

"Light structural checks per definition type (the fields the validators read)."
function _validate_def_shape(def_id::String, dtype::String, def::AbstractDict)
    if dtype == "object"
        props = get(def, "properties", nothing)
        props === nothing || props isa AbstractDict ||
            throw(InvalidLexiconError("Definition $def_id properties must be an object"))
        for (k, v) in props
            v isa AbstractDict && haskey(v, "type") ||
                throw(InvalidLexiconError("Property $def_id/$k must be a typed object"))
        end
        req = get(def, "required", nothing)
        req === nothing || (req isa AbstractVector && all(x -> x isa AbstractString, req)) ||
            throw(InvalidLexiconError("Definition $def_id required must be a string array"))
        nullable = get(def, "nullable", nothing)
        nullable === nothing ||
            (nullable isa AbstractVector && all(x -> x isa AbstractString, nullable)) ||
            throw(InvalidLexiconError("Definition $def_id nullable must be a string array"))
    elseif dtype == "array"
        haskey(def, "items") && def["items"] isa AbstractDict &&
            haskey(def["items"], "type") ||
            throw(InvalidLexiconError("Definition $def_id must have a typed items schema"))
    elseif dtype == "ref"
        haskey(def, "ref") && def["ref"] isa AbstractString ||
            throw(InvalidLexiconError("Definition $def_id must have a string ref"))
    elseif dtype == "union"
        haskey(def, "refs") && def["refs"] isa AbstractVector &&
            all(x -> x isa AbstractString, def["refs"]) ||
            throw(InvalidLexiconError("Definition $def_id must have a string refs array"))
    elseif dtype in ("query", "procedure", "subscription")
        # parameters/output/input schemas, when present, must be objects
        for field in ("parameters", "input", "output", "message")
            v = get(def, field, nothing)
            v === nothing || v isa AbstractDict ||
                throw(InvalidLexiconError("Definition $def_id $field must be an object"))
        end
        if dtype == "record"
        end
    elseif dtype == "record"
        haskey(def, "record") && def["record"] isa AbstractDict &&
            get(def["record"], "type", nothing) == "object" ||
            throw(InvalidLexiconError("Definition $def_id must have an object record"))
    elseif dtype == "string"
        fmt = get(def, "format", nothing)
        fmt === nothing || fmt in ("datetime", "uri", "at-uri", "did", "handle",
                                   "at-identifier", "nsid", "cid", "language",
                                   "tid", "record-key") ||
            throw(InvalidLexiconError("Definition $def_id has invalid string format: $fmt"))
    end
    return nothing
end

"""
    Lexicons()

A collection of lexicon documents with cross-document definition resolution.
Add docs with [`add_lexicon!`](@ref), resolve definitions with
[`get_def`](@ref).
"""
mutable struct Lexicons
    docs::Dict{String,Dict{String,Any}}
end

Lexicons() = Lexicons(Dict{String,Dict{String,Any}}())

"""
    add_lexicon!(lexicons, doc) -> Lexicons

Validate and register a lexicon document. Doc-relative references
(`"#main"`, `"#someDef"`) are rewritten to absolute NSID refs at
registration, like the TS reference's `resolveLexiconDocRefs`.
"""
function add_lexicon!(lexicons::Lexicons, doc::AbstractDict)
    parsed = parse_lexicon_doc(doc)
    nsid = String(parsed["id"])
    _resolve_relative_refs!(parsed, nsid)
    lexicons.docs[nsid] = parsed
    return lexicons
end

"Recursively rewrite `#fragment` refs to absolute `<nsid>#fragment` refs."
function _resolve_relative_refs!(node, nsid::String)
    node isa AbstractDict || return nothing
    for (k, v) in node
        if k == "ref" && v isa AbstractString && startswith(v, "#")
            node[k] = nsid * String(v)
        elseif k == "refs" && v isa AbstractVector
            for (i, r) in enumerate(v)
                if r isa AbstractString && startswith(r, "#")
                    v[i] = nsid * String(r)
                end
            end
        elseif v isa AbstractDict
            _resolve_relative_refs!(v, nsid)
        elseif v isa AbstractVector
            for item in v
                item isa AbstractDict && _resolve_relative_refs!(item, nsid)
            end
        end
    end
    return nothing
end

add_lexicon!(lexicons::Lexicons, docs) =
    (for d in docs; add_lexicon!(lexicons, d); end; lexicons)

"""
    get_def(lexicons, ref) -> Union{Dict, Nothing}

Resolve a definition reference: `"nsid#defId"` or `"nsid"` (implicitly
`#main`). `nothing` when the doc or definition is unknown.
"""
function get_def(lexicons::Lexicons, ref::AbstractString)::Union{Dict{String,Any},Nothing}
    uri = to_lex_uri(String(ref))
    hash_idx = findlast('#', uri)
    hash_idx === nothing && return nothing
    nsid = uri[1:prevind(uri, hash_idx)]
    def_id = uri[nextind(uri, hash_idx):end]
    doc = get(lexicons.docs, nsid, nothing)
    doc === nothing && return nothing
    defs = doc["defs"]
    return get(defs, def_id, nothing)
end

"""
    get_def_or_throw(lexicons, ref) -> Dict

Like [`get_def`](@ref) but throws `LexiconDefNotFoundError`.
"""
function get_def_or_throw(lexicons::Lexicons, ref::AbstractString)::Dict{String,Any}
    def = get_def(lexicons, ref)
    def === nothing &&
        throw(LexiconDefNotFoundError("Lexicon not found: $ref"))
    return def
end
