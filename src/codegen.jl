#= codegen.jl — Ahead-of-time AT Protocol Lexicon → Julia code generator =#

module LexiconCodegen

using JSON

const _JULIA_RESERVED_KEYWORDS = Set([
    "baremodule", "begin", "break", "catch", "const", "continue", "do", "else",
    "elseif", "end", "export", "false", "finally", "for", "function", "global",
    "if", "import", "in", "isa", "let", "local", "macro", "module", "quote",
    "return", "struct", "true", "try", "using", "where", "while",
])

_pascal_seg(s::AbstractString) = isempty(s) ? "" : uppercasefirst(String(s))
_pascal_nsid(nsid::AbstractString) = join(_pascal_seg.(split(nsid, '.')))

function _canonical_type_tag(nsid::AbstractString, dname::AbstractString)
    return dname == "main" ? String(nsid) : string(nsid, '#', dname)
end

function _resolve_ref(current_nsid::AbstractString, ref::AbstractString)
    if startswith(ref, '#')
        return (String(current_nsid), String(ref[2:end]))
    elseif occursin('#', ref)
        ns, def = split(ref, '#'; limit=2)
        return (String(ns), String(def))
    else
        return (String(ref), "main")
    end
end

function _struct_name(nsid::AbstractString, dname::AbstractString, suffix::AbstractString="")
    base = dname == "main" ? _pascal_nsid(nsid) : _pascal_nsid(nsid) * _pascal_seg(dname)
    return base * suffix
end

function _sanitize_field_name(prop::AbstractString)
    s = String(prop)
    if s in _JULIA_RESERVED_KEYWORDS
        return (s * "_", true)
    end
    return (s, false)
end

function _escape_docstring(s::AbstractString)
    out = replace(String(s), "\\" => "\\\\", "\"\"\"" => "\\\"\\\"\\\"", "\$" => "\\\$")
    # Avoid breaking triple-quoted string if text ends with a bare quote
    endswith(out, '"') && (out *= " ")
    return out
end

function _collect_lexicons(lexicons_dir::AbstractString)
    paths = String[]
    for (root, _, files) in walkdir(lexicons_dir)
        for file in files
            endswith(lowercase(file), ".json") && push!(paths, joinpath(root, file))
        end
    end
    sort!(paths)
    docs = Dict{String, Dict{String, Any}}()
    for p in paths
        d = JSON.parsefile(p, Dict{String, Any})
        docs[String(d["id"])] = d
    end
    return docs
end

# Representation of a generated concrete struct or alias node.
struct _TypeNode
    key::String                  # Unique graph key, e.g. "app.bsky.feed.post#main" or "...#main.input"
    julia_name::String           # e.g. "AppBskyFeedPost"
    kind::Symbol                 # :record, :object, :params, :input, :output, :string_alias, :array_alias, :token
    nsid::String
    def_name::String
    lex_type_tag::Union{String, Nothing}
    record_key::Union{String, Nothing}
    description::Union{String, Nothing}
    schema::Dict{String, Any}
end

function _collect_union_members(docs::Dict{String, Dict{String, Any}})
    members = Set{String}()
    function walk(nsid::String, s)
        s isa AbstractDict || return
        t = get(s, "type", nothing)
        if t == "union"
            for r in get(s, "refs", Any[])
                tn, td = _resolve_ref(nsid, String(r))
                push!(members, "$tn#$td")
            end
        end
        for (_, v) in s
            if v isa AbstractDict
                walk(nsid, v)
            elseif v isa AbstractVector
                for item in v
                    item isa AbstractDict && walk(nsid, item)
                end
            end
        end
    end
    for (nsid, doc) in docs
        for (_, ddef) in get(doc, "defs", Dict{String, Any}())
            walk(nsid, ddef)
        end
    end
    return members
end

function _build_type_nodes(docs::Dict{String, Dict{String, Any}})
    nodes = Dict{String, _TypeNode}()
    for nsid in sort!(collect(keys(docs)))
        doc = docs[nsid]
        defs = get(doc, "defs", Dict{String, Any}())
        for dname in sort!(collect(keys(defs)))
            ddef = defs[dname]
            t = String(ddef["type"])
            key = "$nsid#$dname"
            desc = haskey(ddef, "description") ? String(ddef["description"]) : nothing

            if t == "record"
                rec_schema = ddef["record"]
                rkey = haskey(ddef, "key") ? String(ddef["key"]) : "any"
                nodes[key] = _TypeNode(
                    key, _struct_name(nsid, dname), :record,
                    nsid, dname, _canonical_type_tag(nsid, dname), rkey,
                    desc, rec_schema,
                )
            elseif t == "object"
                nodes[key] = _TypeNode(
                    key, _struct_name(nsid, dname), :object,
                    nsid, dname, _canonical_type_tag(nsid, dname), nothing,
                    desc, ddef,
                )
            elseif t == "string"
                nodes[key] = _TypeNode(
                    key, _struct_name(nsid, dname), :string_alias,
                    nsid, dname, nothing, nothing, desc, ddef,
                )
            elseif t == "array"
                nodes[key] = _TypeNode(
                    key, _struct_name(nsid, dname), :array_alias,
                    nsid, dname, nothing, nothing, desc, ddef,
                )
            elseif t == "token"
                nodes[key] = _TypeNode(
                    key, _struct_name(nsid, dname), :token,
                    nsid, dname, _canonical_type_tag(nsid, dname), nothing, desc, ddef,
                )
            elseif t in ("query", "procedure", "subscription")
                if haskey(ddef, "parameters")
                    pkey = "$key.parameters"
                    nodes[pkey] = _TypeNode(
                        pkey, _struct_name(nsid, dname, "Params"), :params,
                        nsid, dname, nothing, nothing,
                        "Query parameters for `$nsid`.", ddef["parameters"],
                    )
                end
                if haskey(ddef, "input") && haskey(ddef["input"], "schema")
                    ischema = ddef["input"]["schema"]
                    if get(ischema, "type", nothing) == "object"
                        ikey = "$key.input"
                        nodes[ikey] = _TypeNode(
                            ikey, _struct_name(nsid, dname, "Input"), :input,
                            nsid, dname, nothing, nothing,
                            "Request input body for `$nsid`.", ischema,
                        )
                    end
                end
                if haskey(ddef, "output") && haskey(ddef["output"], "schema")
                    oschema = ddef["output"]["schema"]
                    if get(oschema, "type", nothing) == "object"
                        okey = "$key.output"
                        nodes[okey] = _TypeNode(
                            okey, _struct_name(nsid, dname, "Output"), :output,
                            nsid, dname, nothing, nothing,
                            "Response output body for `$nsid`.", oschema,
                        )
                    end
                end
            end
        end
    end
    return nodes
end

function _direct_deps(node::_TypeNode)
    deps = String[]
    node.kind in (:token, :string_alias) && return deps

    function walk(s)
        s isa AbstractDict || return
        t = get(s, "type", nothing)
        if t == "ref"
            tn, td = _resolve_ref(node.nsid, String(s["ref"]))
            push!(deps, "$tn#$td")
        elseif t == "array"
            walk(get(s, "items", nothing))
        elseif t == "object" || t == "params"
            for (_, v) in get(s, "properties", Dict{String, Any}())
                walk(v)
            end
        end
        # Note: `union` resolves to `LexiconObject` (already defined), so no ordering dep!
    end

    walk(node.schema)
    return sort!(unique!(deps))
end

"""
Topologically sort all type nodes, automatically breaking any direct-ref struct
cycles by recording back-edges `(src_key, target_key)` whose targets receive an
`Abstract<Name> <: LexiconObject` supertype + `JSON.@choosetype` bridge.
"""
function _topo_sort_with_cycle_breaks(nodes::Dict{String, _TypeNode})
    color = Dict{String, Int}() # 0=unvisited, 1=visiting, 2=done
    order = String[]
    back_edges = Set{Tuple{String, String}}()
    abstract_targets = Set{String}()

    function dfs(u::String)
        color[u] = 1
        for v in _direct_deps(nodes[u])
            haskey(nodes, v) || continue
            c = get(color, v, 0)
            if c == 0
                dfs(v)
            elseif c == 1
                push!(back_edges, (u, v))
                push!(abstract_targets, v)
            end
        end
        color[u] = 2
        push!(order, u)
    end

    for k in sort!(collect(keys(nodes)))
        get(color, k, 0) == 0 && dfs(k)
    end

    return order, back_edges, abstract_targets
end

function _julia_type_expr(
    schema::AbstractDict,
    src_node::_TypeNode,
    nodes::Dict{String, _TypeNode},
    back_edges::Set{Tuple{String, String}},
)
    t = String(schema["type"])
    if t == "boolean"
        return "Bool"
    elseif t == "integer"
        return "Int"
    elseif t == "string"
        fmt = get(schema, "format", nothing)
        fmt == "did" && return "DID"
        fmt == "handle" && return "Handle"
        fmt == "nsid" && return "NSID"
        fmt == "at-uri" && return "AtUri"
        fmt == "record-key" && return "RecordKey"
        fmt == "tid" && return "TID"
        return "String"
    elseif t == "bytes"
        return "ATBytes"
    elseif t == "cid-link"
        return "CIDLink"
    elseif t == "blob"
        return "BlobRef"
    elseif t == "unknown" || t == "union"
        return "LexiconObject"
    elseif t == "array"
        elem = _julia_type_expr(schema["items"], src_node, nodes, back_edges)
        return "Vector{$elem}"
    elseif t == "ref"
        tn, td = _resolve_ref(src_node.nsid, String(schema["ref"]))
        target_key = "$tn#$td"
        target_node = nodes[target_key]
        if (src_node.key, target_key) in back_edges
            return "Abstract" * target_node.julia_name
        end
        return target_node.julia_name
    else
        error("Unsupported Lexicon schema type '$t' in $(src_node.key)")
    end
end

function _emit_struct_doc(io::IO, node::_TypeNode)
    println(io, "\"\"\"")
    println(io, "    ", node.julia_name)
    println(io)
    if !isnothing(node.description) && !isempty(strip(node.description))
        println(io, _escape_docstring(node.description))
        println(io)
    end
    if !isnothing(node.lex_type_tag)
        println(io, "Lexicon: `", node.lex_type_tag, "` (`", node.kind, "`).")
    else
        println(io, "Lexicon: `", node.nsid, "` (`", node.kind, "`).")
    end
    props = get(node.schema, "properties", Dict{String, Any}())
    if !isempty(props)
        req_set = Set(String.(get(node.schema, "required", Any[])))
        null_set = Set(String.(get(node.schema, "nullable", Any[])))
        println(io)
        println(io, "# Fields")
        for pname in sort!(collect(keys(props)))
            pdef = props[pname]
            jname, renamed = _sanitize_field_name(pname)
            opt_tag = (pname in req_set && !(pname in null_set)) ? "required" : "optional"
            pdesc = haskey(pdef, "description") ? " — " * _escape_docstring(String(pdef["description"])) : ""
            extra = ""
            if get(pdef, "type", nothing) == "union"
                refs = join(String.(get(pdef, "refs", Any[])), ", ")
                closed = get(pdef, "closed", false) ? "closed" : "open"
                extra = " [$closed union: `$refs`]"
            elseif get(pdef, "type", nothing) == "array" &&
                   get(get(pdef, "items", Dict()), "type", nothing) == "union"
                refs = join(String.(get(pdef["items"], "refs", Any[])), ", ")
                closed = get(pdef["items"], "closed", false) ? "closed" : "open"
                extra = " [array of $closed union: `$refs`]"
            end
            wire = renamed ? " (JSON key `\"$pname\"`)" : ""
            println(io, "- `", jname, "` (", opt_tag, wire, ")", pdesc, extra)
        end
    end
    println(io, "\"\"\"")
end

function _emit_types_file(
    path::AbstractString,
    order::Vector{String},
    nodes::Dict{String, _TypeNode},
    back_edges::Set{Tuple{String, String}},
    abstract_targets::Set{String},
    union_members::Set{String},
)
    open(path, "w") do io
        println(io, "# AUTO-GENERATED by scripts/generate_lexicons.jl — DO NOT EDIT BY HAND.")
        println(io, "# Regenerate with: julia --project=. scripts/generate_lexicons.jl")
        println(io)

        # 1. Forward-declare cycle-breaking abstract supertypes (if any).
        if !isempty(abstract_targets)
            println(io, "# Cycle-breaking abstract supertypes")
            for k in sort!(collect(abstract_targets))
                n = nodes[k]
                println(io, "abstract type Abstract", n.julia_name, " <: LexiconObject end")
            end
            println(io)
        end

        # 2. Emit tokens & aliases & structs in topological order.
        for k in order
            node = nodes[k]
            if node.kind == :token
                println(io, "\"\"\"")
                println(io, "    ", node.julia_name)
                println(io)
                if !isnothing(node.description) && !isempty(strip(node.description))
                    println(io, _escape_docstring(node.description))
                    println(io)
                end
                println(io, "Lexicon token `\"", node.lex_type_tag, "\"`.")
                println(io, "\"\"\"")
                println(io, "const ", node.julia_name, " = ", repr(node.lex_type_tag))
                println(io)
            elseif node.kind == :string_alias
                println(io, "\"\"\"")
                println(io, "    ", node.julia_name)
                println(io)
                if !isnothing(node.description) && !isempty(strip(node.description))
                    println(io, _escape_docstring(node.description))
                    println(io)
                end
                kv = get(node.schema, "knownValues", Any[])
                if !isempty(kv)
                    println(io, "Known values: ", join(("`$(_escape_docstring(String(v)))`" for v in kv), ", "), ".")
                end
                println(io, "\"\"\"")
                println(io, "const ", node.julia_name, " = String")
                println(io)
            elseif node.kind == :array_alias
                elem_t = _julia_type_expr(node.schema["items"], node, nodes, back_edges)
                println(io, "\"\"\"")
                println(io, "    ", node.julia_name)
                println(io)
                println(io, "Lexicon array alias for `", node.nsid, "#", node.def_name, "`.")
                println(io, "\"\"\"")
                println(io, "const ", node.julia_name, " = Vector{", elem_t, "}")
                println(io)
            else
                supertype_str = if k in abstract_targets
                    "Abstract" * node.julia_name
                elseif node.kind == :record
                    "LexiconRecord"
                elseif node.kind == :object
                    "LexiconObject"
                elseif node.kind == :params
                    "LexiconParams"
                elseif node.kind == :input
                    "LexiconInput"
                elseif node.kind == :output
                    "LexiconOutput"
                else
                    "LexiconModel"
                end

                props = get(node.schema, "properties", Dict{String, Any}())
                req_set = Set(String.(get(node.schema, "required", Any[])))
                null_set = Set(String.(get(node.schema, "nullable", Any[])))

                req_props = sort!(filter(p -> (p in req_set) && !(p in null_set), collect(keys(props))))
                opt_props = sort!(filter(p -> !((p in req_set) && !(p in null_set)), collect(keys(props))))

                renamed_fields = Tuple{String, String}[]

                _emit_struct_doc(io, node)
                if isempty(props)
                    println(io, "struct ", node.julia_name, " <: ", supertype_str, " end")
                else
                    println(io, "Base.@kwdef struct ", node.julia_name, " <: ", supertype_str)

                    for pname in req_props
                        pdef = props[pname]
                        jname, renamed = _sanitize_field_name(pname)
                        renamed && push!(renamed_fields, (jname, pname))
                        jtype = _julia_type_expr(pdef, node, nodes, back_edges)
                        println(io, "    ", jname, "::", jtype)
                    end

                    for pname in opt_props
                        pdef = props[pname]
                        jname, renamed = _sanitize_field_name(pname)
                        renamed && push!(renamed_fields, (jname, pname))
                        jtype = _julia_type_expr(pdef, node, nodes, back_edges)
                        println(io, "    ", jname, "::Union{", jtype, ", Nothing} = nothing")
                    end

                    println(io, "end")
                end

                if !isempty(renamed_fields)
                    entries = join(("$(jn) = (name = :$(pn),)" for (jn, pn) in renamed_fields), ", ")
                    println(io, "StructUtils.fieldtags(::StructUtils.StructStyle, ::Type{", node.julia_name, "}) = (", entries, ",)")
                end

                if !isnothing(node.lex_type_tag)
                    println(io, "lexicon_type(::Type{", node.julia_name, "}) = ", repr(node.lex_type_tag))
                end
                if node.kind == :object && (k in union_members)
                    println(io, "needs_type_tag(::Type{", node.julia_name, "}) = true")
                end
                if node.kind == :record && !isnothing(node.record_key)
                    println(io, "record_key_type(::Type{", node.julia_name, "}) = ", repr(node.record_key))
                end
                if k in abstract_targets
                    println(io, "JSON.@choosetype Abstract", node.julia_name, " _ -> ", node.julia_name)
                end
                println(io)
            end
        end
    end
end

function _emit_registry_file(
    path::AbstractString,
    order::Vector{String},
    nodes::Dict{String, _TypeNode},
)
    open(path, "w") do io
        println(io, "# AUTO-GENERATED by scripts/generate_lexicons.jl — DO NOT EDIT BY HAND.")
        println(io)
        println(io, "function _register_lexicon_types!()")
        for k in order
            node = nodes[k]
            if node.kind in (:record, :object) && !isnothing(node.lex_type_tag)
                println(io, "    LEXICON_TYPES[", repr(node.lex_type_tag), "] = ", node.julia_name)
                # Also register explicit `#main` alias for main defs so both forms resolve cleanly.
                if node.def_name == "main"
                    println(io, "    LEXICON_TYPES[", repr(node.nsid * "#main"), "] = ", node.julia_name)
                end
            elseif node.kind == :token && !isnothing(node.lex_type_tag)
                println(io, "    LEXICON_TOKENS[", repr(node.lex_type_tag), "] = ", node.julia_name)
            end
        end
        println(io, "    return nothing")
        println(io, "end")
        println(io, "_register_lexicon_types!()")
    end
end

function _resolve_io_type(
    nsid::String,
    dname::String,
    field::String,
    io_def::AbstractDict,
    nodes::Dict{String, _TypeNode},
)
    haskey(io_def, "schema") || return "nothing"
    schema = io_def["schema"]
    st = String(schema["type"])
    if st == "object"
        return nodes["$nsid#$dname.$field"].julia_name
    elseif st == "ref"
        tn, td = _resolve_ref(nsid, String(schema["ref"]))
        return nodes["$tn#$td"].julia_name
    elseif st == "union"
        return "LexiconObject"
    else
        error("Unsupported endpoint $field schema type '$st' in $nsid#$dname")
    end
end

function _emit_errors_vec(errors_raw)
    isempty(errors_raw) && return "EndpointError[]"
    parts = String[]
    for e in errors_raw
        ename = repr(String(e["name"]))
        edesc = haskey(e, "description") ? repr(String(e["description"])) : "nothing"
        push!(parts, "EndpointError($ename, $edesc)")
    end
    return "[" * join(parts, ", ") * "]"
end

function _emit_endpoints_file(
    path::AbstractString,
    docs::Dict{String, Dict{String, Any}},
    nodes::Dict{String, _TypeNode},
)
    open(path, "w") do io
        println(io, "# AUTO-GENERATED by scripts/generate_lexicons.jl — DO NOT EDIT BY HAND.")
        println(io)
        println(io, "function _register_lexicon_endpoints!()")
        for nsid in sort!(collect(keys(docs)))
            doc = docs[nsid]
            defs = get(doc, "defs", Dict{String, Any}())
            for dname in sort!(collect(keys(defs)))
                ddef = defs[dname]
                t = String(ddef["type"])
                t in ("query", "procedure", "subscription") || continue
                key = "$nsid#$dname"
                desc = haskey(ddef, "description") ? repr(String(ddef["description"])) : "nothing"
                errs = _emit_errors_vec(get(ddef, "errors", Any[]))

                if t == "query"
                    params_t = haskey(ddef, "parameters") ? nodes["$key.parameters"].julia_name : "nothing"
                    out_t = haskey(ddef, "output") ? _resolve_io_type(nsid, dname, "output", ddef["output"], nodes) : "nothing"
                    out_enc = (haskey(ddef, "output") && haskey(ddef["output"], "encoding")) ? repr(String(ddef["output"]["encoding"])) : "nothing"
                    println(io, "    LEXICON_ENDPOINTS[", repr(nsid), "] = QueryEndpoint(NSID(", repr(nsid), "), ", desc, ", ", params_t, ", ", out_t, ", ", out_enc, ", ", errs, ")")
                elseif t == "procedure"
                    in_t = haskey(ddef, "input") ? _resolve_io_type(nsid, dname, "input", ddef["input"], nodes) : "nothing"
                    in_enc = (haskey(ddef, "input") && haskey(ddef["input"], "encoding")) ? repr(String(ddef["input"]["encoding"])) : "nothing"
                    out_t = haskey(ddef, "output") ? _resolve_io_type(nsid, dname, "output", ddef["output"], nodes) : "nothing"
                    out_enc = (haskey(ddef, "output") && haskey(ddef["output"], "encoding")) ? repr(String(ddef["output"]["encoding"])) : "nothing"
                    println(io, "    LEXICON_ENDPOINTS[", repr(nsid), "] = ProcedureEndpoint(NSID(", repr(nsid), "), ", desc, ", ", in_t, ", ", in_enc, ", ", out_t, ", ", out_enc, ", ", errs, ")")
                elseif t == "subscription"
                    params_t = haskey(ddef, "parameters") ? nodes["$key.parameters"].julia_name : "nothing"
                    msg_t = haskey(ddef, "message") ? _resolve_io_type(nsid, dname, "message", ddef["message"], nodes) : "nothing"
                    println(io, "    LEXICON_ENDPOINTS[", repr(nsid), "] = SubscriptionEndpoint(NSID(", repr(nsid), "), ", desc, ", ", params_t, ", ", msg_t, ", ", errs, ")")
                end
            end
        end
        println(io, "    return nothing")
        println(io, "end")
        println(io, "_register_lexicon_endpoints!()")
    end
end

# Build nested namespace tree: seg => (children::Dict, leaf_nsid::Union{String, Nothing})
mutable struct _NsTree
    children::Dict{String, _NsTree}
    leaf_nsid::Union{String, Nothing}
end
_NsTree() = _NsTree(Dict{String, _NsTree}(), nothing)

function _emit_namespaces_file(
    path::AbstractString,
    docs::Dict{String, Dict{String, Any}},
    nodes::Dict{String, _TypeNode},
)
    root = _NsTree()
    for nsid in sort!(collect(keys(docs)))
        cur = root
        for seg in split(nsid, '.')
            pseg = _pascal_seg(seg)
            cur = get!(cur.children, pseg) do
                _NsTree()
            end
        end
        cur.leaf_nsid = nsid
    end

    open(path, "w") do io
        println(io, "# AUTO-GENERATED by scripts/generate_lexicons.jl — DO NOT EDIT BY HAND.")
        println(io, "# Hierarchical NSID namespace modules aliasing canonical types in ATProto.API.")
        println(io)

        function emit_node(mod_name::String, tree::_NsTree, depth::Int)
            indent = "    "^(depth - 1)
            println(io, indent, "module ", mod_name)
            if !isnothing(tree.leaf_nsid)
                nsid = tree.leaf_nsid
                doc = docs[nsid]
                defs = get(doc, "defs", Dict{String, Any}())
                api_expr = repeat("parentmodule(", depth) * "@__MODULE__" * repeat(")", depth)
                println(io, indent, "    const _API = ", api_expr)
                println(io, indent, "    const NSID_STR = ", repr(nsid))
                for dname in sort!(collect(keys(defs)))
                    ddef = defs[dname]
                    t = String(ddef["type"])
                    key = "$nsid#$dname"
                    if t in ("record", "object", "string", "array", "token")
                        alias = _pascal_seg(dname)
                        target = nodes[key].julia_name
                        println(io, indent, "    const ", alias, " = _API.", target)
                    elseif t in ("query", "procedure", "subscription")
                        println(io, indent, "    const ENDPOINT = _API.LEXICON_ENDPOINTS[", repr(nsid), "]")
                        if haskey(ddef, "parameters")
                            println(io, indent, "    const Params = _API.", nodes["$key.parameters"].julia_name)
                        end
                        if haskey(ddef, "input") && haskey(ddef["input"], "schema")
                            in_t = _resolve_io_type(nsid, dname, "input", ddef["input"], nodes)
                            println(io, indent, "    const Input = _API.", in_t)
                        end
                        if haskey(ddef, "output") && haskey(ddef["output"], "schema")
                            out_t = _resolve_io_type(nsid, dname, "output", ddef["output"], nodes)
                            println(io, indent, "    const Output = _API.", out_t)
                        end
                    end
                end
            end
            for child_name in sort!(collect(keys(tree.children)))
                emit_node(child_name, tree.children[child_name], depth + 1)
            end
            println(io, indent, "end # module ", mod_name)
        end

        for top_name in sort!(collect(keys(root.children)))
            emit_node(top_name, root.children[top_name], 1)
            println(io)
        end
    end
end

"""
    generate_lexicons(lexicons_dir, out_dir) -> NamedTuple

Generate Julia Lexicon types, `\$type` registries, XRPC endpoint specs, and
hierarchical namespace modules from all `.json` schemas under `lexicons_dir`
into `out_dir`.
"""
function generate_lexicons(lexicons_dir::AbstractString, out_dir::AbstractString)
    docs = _collect_lexicons(lexicons_dir)
    union_members = _collect_union_members(docs)
    nodes = _build_type_nodes(docs)
    order, back_edges, abstract_targets = _topo_sort_with_cycle_breaks(nodes)

    mkpath(out_dir)
    _emit_types_file(joinpath(out_dir, "types.jl"), order, nodes, back_edges, abstract_targets, union_members)
    _emit_registry_file(joinpath(out_dir, "registry.jl"), order, nodes)
    _emit_endpoints_file(joinpath(out_dir, "endpoints.jl"), docs, nodes)
    _emit_namespaces_file(joinpath(out_dir, "namespaces.jl"), docs, nodes)

    return (
        lexicons = length(docs),
        types = length(nodes),
        cycle_breaks = length(abstract_targets),
        union_members = length(union_members),
    )
end

end # module LexiconCodegen
