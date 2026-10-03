# Lexicon-compatible JSON serialization: the bridge between native values and
# XRPC JSON bodies. Port of @atproto/lexicon's stringifyLex / jsonStringToLex:
#
#   - byte strings serialize as {"$bytes": "<base64, unpadded>"}
#   - CIDs serialize as {"$link": "<cid string>"}
#   - object keys must be strings; undefined values are dropped

"Recursively convert native values to lexicon-JSON-compatible values."
function _lex_to_json(value)
    if value === nothing
        return nothing
    elseif value isa DagBytes
        return Dict{String,Any}("\$bytes" => base64_encode(value.bytes))
    elseif value isa CID
        return Dict{String,Any}("\$link" => string(value))
    elseif value isa Bool
        return value
    elseif value isa Integer
        return value
    elseif value isa AbstractFloat
        return Float64(value)
    elseif value isa AbstractString
        return String(value)
    elseif value isa AbstractVector
        return Any[_lex_to_json(v) for v in value]
    elseif value isa AbstractDict
        out = Dict{String,Any}()
        for (k, v) in value
            k isa AbstractString || throw(ArgumentError(
                "lexicon object keys must be strings, got $(typeof(k))"))
            converted = _lex_to_json(v)
            converted === nothing && continue  # drop undefined
            out[String(k)] = converted
        end
        return out
    end
    throw(ArgumentError("cannot lexicon-serialize value of type $(typeof(value))"))
end

"""
    serialize_lex(value) -> String

Serialize a native value tree to lexicon-compatible JSON text
(`DagBytes` → `{"\$bytes"}`, `CID` → `{"\$link"}`).
"""
serialize_lex(value)::String = JSON.json(_lex_to_json(value))

"Recursively restore native values from parsed JSON (reverse of `_lex_to_json`)."
function _json_to_lex(value)
    if value isa AbstractDict
        if length(value) == 1 && haskey(value, "\$bytes") && value["\$bytes"] isa AbstractString
            return DagBytes(base64_decode(value["\$bytes"]))
        elseif length(value) == 1 && haskey(value, "\$link") && value["\$link"] isa AbstractString
            return cid_parse(value["\$link"])
        end
        return Dict{String,Any}(String(k) => _json_to_lex(v) for (k, v) in value)
    elseif value isa AbstractVector
        return Any[_json_to_lex(v) for v in value]
    end
    return value
end

"""
    parse_lex(text) -> Any

Parse lexicon-compatible JSON, restoring `DagBytes` from `{"\$bytes"}` and
`CID` from `{"\$link"}` markers.
"""
parse_lex(text::AbstractString) = _json_to_lex(JSON.parse(String(text)))
