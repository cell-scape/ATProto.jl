# Generates src/API/lexicons_data.jl and src/API/namespaces.jl from the
# official lexicon corpus (docs/reference/atproto/lexicons).
#
# Run from the repo root:
#   julia --project=. tools/generate_api.jl
#
# The output is committed to the repo (deterministic), like the TS api
# package's generated artifacts.

using JSON

const ROOT = dirname(@__DIR__)
const LEXDIR = joinpath(ROOT, "docs", "reference", "atproto", "lexicons")
const OUT_LEXICONS = joinpath(ROOT, "src", "API", "lexicons_data.jl")
const OUT_NAMESPACES = joinpath(ROOT, "src", "API", "namespaces.jl")

# --- load all docs ----------------------------------------------------------------

function load_docs()
    docs = Dict{String,Any}()
    for (root, _, files) in walkdir(LEXDIR)
        for f in files
            endswith(f, ".json") || continue
            doc = JSON.parsefile(joinpath(root, f))
            docs[doc["id"]] = doc
        end
    end
    return docs
end

# --- Julia literal emitter ----------------------------------------------------------

"Emit a double-quoted Julia string literal (repr adds quotes + escapes)."
jl_str(s::AbstractString) = repr(String(s))

function jl_literal(v)
    if v === nothing
        return "nothing"
    elseif v isa Bool
        return string(v)
    elseif v isa Integer
        return string(v)
    elseif v isa AbstractFloat
        return string(v)
    elseif v isa AbstractString
        return jl_str(v)
    elseif v isa AbstractVector
        return "[" * join([jl_literal(x) for x in v], ", ") * "]"
    elseif v isa AbstractDict
        parts = String[]
        for k in sort(collect(keys(v)))
            push!(parts, jl_str(String(k)) * " => " * jl_literal(v[k]))
        end
        return "Dict{String,Any}(" * join(parts, ", ") * ")"
    end
    error("cannot emit literal for $(typeof(v))")
end

# --- naming --------------------------------------------------------------------------

"camelCase (or kebab/dotted) identifier to snake_case, preserving digits."
function snake_case(name::AbstractString)
    out = Char[]
    prev_lower = false
    for c in name
        if isuppercase(c)
            prev_lower && push!(out, '_')
            push!(out, lowercase(c))
            prev_lower = false
        elseif c == '-' || c == '_'
            push!(out, '_')
            prev_lower = false
        else
            push!(out, c)
            prev_lower = true
        end
    end
    return String(out)
end

"is this identifier a valid Julia identifier?"
function is_jl_ident(s)
    isempty(s) && return false
    c1 = first(s)
    isidentfirst = ('a' <= c1 <= 'z') || ('A' <= c1 <= 'Z') || c1 == '_'
    isidentrest(c) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') || c == '_'
    return isidentfirst && all(isidentrest, s)
end

# --- namespace generation ---------------------------------------------------------

struct MethodInfo
    nsid::String
    kind::String          # query | procedure | subscription
    params::Vector{Pair{String,Any}}   # name => param schema (sorted)
    description::String
end

function collect_methods(docs)
    methods = MethodInfo[]
    for nsid in sort(collect(keys(docs)))
        main = get(docs[nsid]["defs"], "main", nothing)
        main isa AbstractDict || continue
        dtype = get(main, "type", "")
        dtype in ("query", "procedure", "subscription") || continue
        params = Pair{String,Any}[]
        pdef = get(main, "parameters", nothing)
        if pdef isa AbstractDict
            props = get(pdef, "properties", nothing)
            if props isa AbstractDict
                for (k, v) in sort(collect(pairs(Dict{String,Any}(props))); by = first)
                    push!(params, String(k) => v)
                end
            end
        end
        desc = get(main, "description", "")
        desc isa AbstractString || (desc = "")
        push!(methods, MethodInfo(nsid, dtype, params, String(desc)))
    end
    return methods
end

"Group methods into nested modules by NSID segments; returns nested Dicts."
function build_tree(methods)
    tree = Dict{String,Any}()
    for m in methods
        parts = split(m.nsid, '.')
        node = tree
        for p in parts[1:end-1]
            if !haskey(node, p)
                node[p] = Dict{String,Any}()
            end
            node = node[p]
            node isa Dict || error("namespace collision at $(m.nsid)")
        end
        node[parts[end]] = m
    end
    return tree
end

const JULIA_KEYWORDS = Set(["begin", "end", "function", "if", "in", "is", "do",
    "let", "macro", "module", "type", "import", "export", "local", "global",
    "const", "return", "while", "for", "try", "catch", "using", "abstract",
    "baremodule", "quote", "break", "continue", "else", "elseif", "finally",
    "new", "struct", "true", "false", "elseif"])

function method_name(m::MethodInfo, taken::Set{String})::String
    base = snake_case(split(m.nsid, '.')[end])
    base in JULIA_KEYWORDS && (base = base * "_")
    is_jl_ident(base) || error("bad method name for $(m.nsid)")
    name = base
    i = 2
    while name in taken
        name = base * "_" * string(i)
        i += 1
    end
    push!(taken, name)
    return name
end

function escape_kwarg(name::String)
    # kwargs keep their lexicon names verbatim; escape the rare Julia keyword
    kwkeywords = ("in", "out", "end", "begin", "function", "type", "if", "else",
                  "while", "for", "do", "abstract", "mutable", "local", "global",
                  "const", "export", "import", "using", "try", "catch", "return")
    return name in kwkeywords ? "_" * name : name
end

function emit_method(io, m::MethodInfo, taken)
    name = method_name(m, taken)
    nsid = m.nsid
    params = join((escape_kwarg(p.first) * " = nothing" for p in m.params), ", ")
    pass = join((escape_kwarg(p.first) for p in m.params), ", ")

    desc = replace(m.description, "\n" => " ")
    desc = replace(desc, r"\s+" => " ")
    println(io, "\"\"\"")
    println(io, "    $name(client$(isempty(m.params) ? "" : "; " * params))")
    isempty(desc) || println(io)
    isempty(desc) || println(io, desc)
    println(io)
    println(io, "XRPC endpoint: `" * nsid * "` (" * m.kind * ").")
    println(io, "\"\"\"")
    if m.kind == "query"
        if isempty(m.params)
            println(io, "function $name(client)")
            println(io, "    return _call_query(client, \"$nsid\")")
        else
            println(io, "function $name(client; $params)")
            println(io, "    return _call_query(client, \"$nsid\"; $pass)")
        end
    elseif m.kind == "procedure"
        kw = join(vcat([escape_kwarg(p.first) * " = nothing" for p in m.params],
                       ["data = nothing", "encoding = nothing"]), ", ")
        println(io, "function $name(client; $kw)")
        if isempty(m.params)
            println(io, "    return _call_proc(client, \"$nsid\"; data, encoding)")
        else
            println(io, "    return _call_proc(client, \"$nsid\"; $pass, data, encoding)")
        end
    else  # subscription
        if isempty(m.params)
            println(io, "function $name(client)")
            println(io, "    return _call_subscription(client, \"$nsid\")")
        else
            println(io, "function $name(client; $params)")
            println(io, "    return _call_subscription(client, \"$nsid\"; $pass)")
        end
    end
    println(io, "end")
    println(io)
end

function emit_module(io, name::String, node::Dict{String,Any}, indent::String,
                     nsid_prefix::String)
    println(io, indent * "module $name")
    println(io, indent * "import .._API_helpers")
    println(io, indent * "const _call_query = _API_helpers._call_query")
    println(io, indent * "const _call_proc = _API_helpers._call_proc")
    println(io, indent * "const _call_subscription = _API_helpers._call_subscription")
    for (k, v) in sort(collect(pairs(node)); by = first)
        if v isa MethodInfo
            continue  # methods emitted after submodule declarations
        end
    end
    # emit methods first (their names may collide with submodule names otherwise)
    taken = Set{String}()
    for (k, v) in sort(collect(pairs(node)); by = first)
        v isa MethodInfo && emit_method(io, v, taken)
    end
    for (k, v) in sort(collect(pairs(node)); by = first)
        v isa MethodInfo && continue
        emit_module(io, k, v, indent, nsid_prefix * k * ".")
    end
    println(io, indent * "end")
    println(io)
end

# --- run ---------------------------------------------------------------------------

const docs = load_docs()
println("loaded $(length(docs)) lexicon docs")

# 1. lexicons_data.jl
open(OUT_LEXICONS, "w") do io
    println(io, "# Generated by tools/generate_api.jl from docs/reference/atproto/lexicons.")
    println(io, "# Do not edit by hand.")
    println(io)
    println(io, "const OFFICIAL_LEXICONS = Lexicons()")
    println(io)
    for nsid in sort(collect(keys(docs)))
        println(io, "add_lexicon!(OFFICIAL_LEXICONS, $(jl_literal(docs[nsid])))")
    end
    println(io)
    println(io, "# cache of XRPC param types per nsid")
    println(io, "const _PARAM_TYPES = Dict{String,Dict{String,Any}}()")
    println(io, "\"\"\"Param-type maps for XRPC URL encoding, derived from the lexicons.\"\"\"")
    println(io, "function param_types_for(nsid::AbstractString)")
    println(io, "    key = String(nsid)")
    println(io, "    cached = get(_PARAM_TYPES, key, nothing)")
    println(io, "    cached !== nothing && return cached")
    println(io, "    def = get_def_or_throw(OFFICIAL_LEXICONS, key)")
    println(io, "    pdef = get(def, \"parameters\", nothing)")
    println(io, "    out = Dict{String,Any}()")
    println(io, "    if pdef isa AbstractDict")
    println(io, "        props = get(pdef, \"properties\", nothing)")
    println(io, "        if props isa AbstractDict")
    println(io, "            for (k, v) in props")
    println(io, "                out[String(k)] = v")
    println(io, "            end")
    println(io, "        end")
    println(io, "    end")
    println(io, "    _PARAM_TYPES[key] = out")
    println(io, "    return out")
    println(io, "end")
end
println("wrote $OUT_LEXICONS")

# 2. namespaces.jl
methods = collect_methods(docs)
println("collected $(length(methods)) XRPC methods")
tree = build_tree(methods)
open(OUT_NAMESPACES, "w") do io
    println(io, "# Generated by tools/generate_api.jl: client namespaces mirroring the")
    println(io, "# official lexicons (com.atproto.*, app.bsky.*, chat.bsky.*, tools.ozone.*).")
    println(io, "# Do not edit by hand.")
    println(io)
    for (k, v) in sort(collect(pairs(tree)); by = first)
        emit_module(io, k, v, "", "")
    end
end
println("wrote $OUT_NAMESPACES")
