# Lexicon value validators. Port of `packages/lexicon/src/validators/*`.
#
# Each validator returns (ok::Bool, value, err::Union{String,Nothing}) —
# on success `value` may be adjusted (defaults applied); on failure `err`
# carries the path-qualified message, matching the TS reference wording.

const VResult = Tuple{Bool,Any,Union{String,Nothing}}

_ok(value) = (true, value, nothing)
_err(msg::AbstractString) = (false, nothing, String(msg))

_is_undef(v) = v === nothing

_utf8_len(s::AbstractString) = ncodeunits(s)
_grapheme_len(s::AbstractString) = length(collect(Base.Unicode.graphemes(s)))

# --- format validators ------------------------------------------------------------

const _FORMATS = (
    "datetime" => (path, v) -> is_valid_datetime(v) ? _ok(v) :
        _err("$path must be an atproto datetime"),
    "uri" => (path, v) -> _valid_uri(v) ? _ok(v) :
        _err("$path must be a valid URI"),
    "at-uri" => (path, v) -> begin
        try
            uri = AtURI(v)
            ensure_valid_at_identifier(host(uri))
            _ok(v)
        catch
            _err("$path must be a valid at-uri")
        end
    end,
    "did" => (path, v) -> is_valid_did(v) ? _ok(v) :
        _err("$path must be a valid did"),
    "handle" => (path, v) -> is_valid_handle(v) ? _ok(v) :
        _err("$path must be a valid handle"),
    "at-identifier" => (path, v) -> is_valid_at_identifier(v) ? _ok(v) :
        _err("$path must be a valid at-identifier"),
    "nsid" => (path, v) -> is_valid_nsid(v) ? _ok(v) :
        _err("$path must be a valid nsid"),
    "cid" => (path, v) -> (try cid_parse(v); _ok(v)
                           catch; _err("$path must be a valid cid") end),
    "language" => (path, v) -> is_valid_language(v) ? _ok(v) :
        _err("$path must be a valid language"),
    "tid" => (path, v) -> is_valid_tid(v) ? _ok(v) :
        _err("$path must be a valid tid"),
    "record-key" => (path, v) -> is_valid_record_key(v) ? _ok(v) :
        _err("$path must be a valid record-key"),
)

_valid_uri(v::AbstractString) =
    !isempty(v) && occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", v) &&
    tryparse(URIs.URI, v) !== nothing

# --- primitive validators -----------------------------------------------------------

function _v_boolean(path::String, def::Dict, value)::VResult
    if _is_undef(value)
        d = get(def, "default", nothing)
        d isa Bool && return _ok(d)
        return _err("$path must be a boolean")
    end
    value isa Bool || return _err("$path must be a boolean")
    konst = get(def, "const", nothing)
    konst isa Bool && value !== konst && return _err("$path must be $konst")
    return _ok(value)
end

function _v_integer(path::String, def::Dict, value)::VResult
    if _is_undef(value)
        d = get(def, "default", nothing)
        (d isa Integer && !(d isa Bool)) && return _ok(d)
        return _err("$path must be an integer")
    end
    (value isa Integer && !(value isa Bool)) || return _err("$path must be an integer")
    konst = get(def, "const", nothing)
    konst isa Integer && value !== konst && return _err("$path must be $konst")
    enum = get(def, "enum", nothing)
    if enum isa AbstractVector && !(value in enum)
        return _err("$path must be one of ($(join(enum, '|')))")
    end
    maximum = get(def, "maximum", nothing)
    maximum isa Integer && value > maximum &&
        return _err("$path can not be greater than $maximum")
    minimum = get(def, "minimum", nothing)
    minimum isa Integer && value < minimum &&
        return _err("$path can not be less than $minimum")
    return _ok(value)
end

function _v_string(path::String, def::Dict, value)::VResult
    if _is_undef(value)
        d = get(def, "default", nothing)
        d isa AbstractString && return _ok(String(d))
        return _err("$path must be a string")
    end
    value isa AbstractString || return _err("$path must be a string")
    v = String(value)

    konst = get(def, "const", nothing)
    konst isa AbstractString && v != konst && return _err("$path must be $konst")
    enum = get(def, "enum", nothing)
    if enum isa AbstractVector && !(v in enum)
        return _err("$path must be one of ($(join(enum, '|')))")
    end

    # minLength / maxLength count UTF-8 bytes
    min_len = get(def, "minLength", nothing)
    max_len = get(def, "maxLength", nothing)
    if min_len isa Integer || max_len isa Integer
        len = _utf8_len(v)
        if max_len isa Integer && len > max_len
            return _err("$path must not be longer than $max_len characters")
        end
        if min_len isa Integer && len < min_len
            return _err("$path must not be shorter than $min_len characters")
        end
    end

    # minGraphemes / maxGraphemes count user-perceived characters
    min_g = get(def, "minGraphemes", nothing)
    max_g = get(def, "maxGraphemes", nothing)
    if min_g isa Integer || max_g isa Integer
        glen = _grapheme_len(v)
        if max_g isa Integer && glen > max_g
            return _err("$path must not be longer than $max_g graphemes")
        end
        if min_g isa Integer && glen < min_g
            return _err("$path must not be shorter than $min_g graphemes")
        end
    end

    fmt = get(def, "format", nothing)
    if fmt isa AbstractString
        for (name, validator) in _FORMATS
            name == fmt && return validator(path, v)
        end
        return _err("$path has an unknown format: $fmt")
    end
    return _ok(v)
end

function _v_bytes(path::String, def::Dict, value)::VResult
    value isa DagBytes || return _err("$path must be a byte array")
    max_len = get(def, "maxLength", nothing)
    max_len isa Integer && length(value) > max_len &&
        return _err("$path must not be longer than $max_len bytes")
    min_len = get(def, "minLength", nothing)
    min_len isa Integer && length(value) < min_len &&
        return _err("$path must not be shorter than $min_len bytes")
    return _ok(value)
end

_v_cid_link(path::String, ::Dict, value) =
    value isa CID ? _ok(value) : _err("$path must be a cid-link")

_v_unknown(::String, ::Dict, value) = _ok(value)

# --- complex validators ---------------------------------------------------------------

function _v_array(lexicons::Lexicons, path::String, def::Dict, value)::VResult
    value isa AbstractVector || return _err("$path must be an array")
    max_len = get(def, "maxLength", nothing)
    max_len isa Integer && length(value) > max_len &&
        return _err("$path must not have more than $max_len elements")
    min_len = get(def, "minLength", nothing)
    min_len isa Integer && length(value) < min_len &&
        return _err("$path must not have fewer than $min_len elements")
    items_def = def["items"]
    for (i, item) in enumerate(value)
        ok, v, err = validate_lex_ref_variant(lexicons, "$path/$(i - 1)", items_def, item)
        ok || return (false, nothing, err)
    end
    return _ok(value)
end

_v_blob(path::String, ::Dict, value) =
    value isa BlobRef ? _ok(value) : _err("$path should be a blob ref")

function _v_object(lexicons::Lexicons, path::String, def::Dict, value)::VResult
    value isa AbstractDict || return _err("$path must be an object")
    props = get(def, "properties", nothing)
    required = get(def, "required", nothing)
    nullable = get(def, "nullable", nothing)
    result = value
    changed = false
    if props isa AbstractDict
        for (key, prop_def) in props
            key_value = get(value, key, nothing)
            if key_value === nothing && nullable isa AbstractVector && String(key) in nullable
                continue
            end
            if _is_undef(key_value) &&
               !(required isa AbstractVector && String(key) in required)
                # fast path: optional prop with no default
                if (get(prop_def, "type", nothing) in ("integer", "boolean", "string")) &&
                   get(prop_def, "default", nothing) === nothing
                    continue
                elseif !(get(prop_def, "type", nothing) in ("integer", "boolean", "string"))
                    continue
                end
            end
            prop_path = "$path/$key"
            ok, v, err = validate_lex_ref_variant(lexicons, prop_path, prop_def, key_value)
            if _is_undef(ok ? v : key_value)
                if required isa AbstractVector && String(key) in required
                    return _err("$path must have the property \"$key\"")
                end
            elseif !ok
                return (false, nothing, err)
            end
            # apply defaults (shallow clone lazily)
            if ok && !isnothing(v) && !(v === key_value)
                if !changed
                    result = Dict{String,Any}(value)
                    changed = true
                end
                result[String(key)] = v
            end
        end
    end
    return _ok(result)
end

# --- dispatch + refs/unions ------------------------------------------------------------

"""
    validate_lex_ref_variant(lexicons, path, def, value) -> (ok, value, err)

Validate `value` against a lexicon definition, which may be a `ref`, a
`union` of refs, or a concrete type. Open unions pass unlisted `\$type`
values through; closed unions reject them. `#main` references are resolved
in both explicit and implicit forms.
"""
function validate_lex_ref_variant(lexicons::Lexicons, path::String, def::Dict,
                                  value)::VResult
    dtype = get(def, "type", nothing)
    if dtype == "union"
        (value isa AbstractDict && haskey(value, "\$type") &&
         value["\$type"] isa AbstractString) ||
            return _err("$path must be an object which includes the \"\$type\" property")
        vtype = String(value["\$type"])
        refs = def["refs"]
        if !_refs_contain_type(lexicons, refs, vtype)
            if get(def, "closed", false) === true
                return _err("$path \$type must be one of $(join(refs, ", "))")
            end
            return _ok(value)
        end
        concrete = get_def_or_throw(lexicons, vtype)
        return _dispatch(lexicons, path, concrete, value)
    elseif dtype == "ref"
        concrete = get_def_or_throw(lexicons, String(def["ref"]))
        return _dispatch(lexicons, path, concrete, value)
    end
    return _dispatch(lexicons, path, def, value)
end

function _dispatch(lexicons::Lexicons, path::String, def::Dict, value)::VResult
    dtype = get(def, "type", nothing)
    dtype === nothing &&
        return _err("Unexpected lexicon type: nothing")
    dtype == "boolean" && return _v_boolean(path, def, value)
    dtype == "integer" && return _v_integer(path, def, value)
    dtype == "string" && return _v_string(path, def, value)
    dtype == "bytes" && return _v_bytes(path, def, value)
    dtype == "cid-link" && return _v_cid_link(path, def, value)
    dtype == "unknown" && return _v_unknown(path, def, value)
    dtype == "object" && return _v_object(lexicons, path, def, value)
    dtype == "array" && return _v_array(lexicons, path, def, value)
    dtype == "blob" && return _v_blob(path, def, value)
    dtype == "token" && return _ok(value)
    return _err("Unexpected lexicon type: $dtype")
end

"#main handling: explicit `nsid#main` matches an implicit `nsid` ref and vice versa."
function _refs_contain_type(lexicons::Lexicons, refs::AbstractVector, type::AbstractString)::Bool
    lex_uri = to_lex_uri(String(type))
    String(lex_uri) in refs && return true
    if endswith(lex_uri, "#main")
        idx = something(findlast('#', lex_uri), 0)
        stripped = lex_uri[1:prevind(lex_uri, idx)]
        return String(stripped) in refs
    end
    return false
end

# --- entry points (validation.ts) --------------------------------------------------------

"""
    assert_valid_record(lexicons, def, value) -> Any

Validate a record against a `record` definition; throws
`LexiconValidationError`.
"""
function assert_valid_record(lexicons::Lexicons, def::Dict, value)
    record_def = def["record"]
    ok, v, err = _v_object(lexicons, "Record", record_def, value)
    ok || throw(err === nothing ? LexiconValidationError("Record failed validation") : LexiconValidationError(err))
    return v
end

"""
    assert_valid_xrpc_params(lexicons, def, params) -> Dict

Validate query parameters against an XRPC definition's `parameters` schema
(defaults applied). Throws `LexiconValidationError`.
"""
function assert_valid_xrpc_params(lexicons::Lexicons, def::Dict, params)
    params_def = get(def, "parameters", nothing)
    params_def === nothing && return nothing
    value = params isa AbstractDict ? params : Dict{String,Any}()
    ok, v, err = _v_params(lexicons, "Params", params_def, value)
    ok || throw(err === nothing ? LexiconValidationError("Record failed validation") : LexiconValidationError(err))
    return v
end

"""
    assert_valid_xrpc_input(lexicons, def, value) -> Any

Validate a procedure input body against its `input.schema` (as an object).
Throws `LexiconValidationError`.
"""
function assert_valid_xrpc_input(lexicons::Lexicons, def::Dict, value)
    input = get(def, "input", nothing)
    input isa AbstractDict || return nothing
    schema = get(input, "schema", nothing)
    schema isa AbstractDict || return nothing
    ok, v, err = _validate_one_of_obj(lexicons, "Input", schema, value)
    ok || throw(err === nothing ? LexiconValidationError("Record failed validation") : LexiconValidationError(err))
    return v
end

"""
    assert_valid_xrpc_output(lexicons, def, value) -> Any

Validate a query/procedure output body against its `output.schema`.
Throws `LexiconValidationError`.
"""
function assert_valid_xrpc_output(lexicons::Lexicons, def::Dict, value)
    output = get(def, "output", nothing)
    output isa AbstractDict || return nothing
    schema = get(output, "schema", nothing)
    schema isa AbstractDict || return nothing
    ok, v, err = _validate_one_of_obj(lexicons, "Output", schema, value)
    ok || throw(err === nothing ? LexiconValidationError("Record failed validation") : LexiconValidationError(err))
    return v
end

"validateOneOf with mustBeObj=true: bodies must validate as objects."
function _validate_one_of_obj(lexicons::Lexicons, path::String, schema::Dict, value)::VResult
    dtype = get(schema, "type", nothing)
    if dtype == "union"
        (value isa AbstractDict && haskey(value, "\$type") &&
         value["\$type"] isa AbstractString) ||
            return _err("$path must be an object which includes the \"\$type\" property")
        vtype = String(value["\$type"])
        refs = schema["refs"]
        if !_refs_contain_type(lexicons, refs, vtype)
            if get(schema, "closed", false) === true
                return _err("$path \$type must be one of $(join(refs, ", "))")
            end
            return _ok(value)
        end
        concrete = get_def_or_throw(lexicons, vtype)
        return _v_object(lexicons, path, concrete, value)
    elseif dtype == "ref"
        concrete = get_def_or_throw(lexicons, String(schema["ref"]))
        return _v_object(lexicons, path, concrete, value)
    end
    return _v_object(lexicons, path, schema, value)
end

"XRPC parameters validator (params in validators/xrpc.ts)."
function _v_params(lexicons::Lexicons, path::String, def::Dict, value)::VResult
    required_props = Set{String}(String(x) for x in get(def, "required", String[]))
    props = get(def, "properties", nothing)
    result = value
    changed = false
    if props isa AbstractDict
        for (key, prop_def) in props
            key_value = get(value, key, nothing)
            ptype = get(prop_def, "type", nothing)
            ok, v, err = if ptype == "array"
                _v_array(lexicons, String(key), prop_def, key_value)
            else
                _validate_primitive(String(key), prop_def, key_value)
            end
            prop_value = ok ? v : key_value
            if _is_undef(prop_value)
                if String(key) in required_props
                    return _err("$path must have the property \"$key\"")
                end
            elseif !ok
                return (false, nothing, err)
            end
            if ok && !isnothing(v) && !(v === key_value)
                if !changed
                    result = Dict{String,Any}(value)
                    changed = true
                end
                result[String(key)] = v
            end
        end
    end
    return _ok(result)
end

_validate_primitive(path::String, def::Dict, value) = _dispatch(_EMPTY_LEXICONS, path, def, value)

# a shared empty collection for primitive-only validation paths
const _EMPTY_LEXICONS = Lexicons()
