# Record key syntax. Port of `packages/syntax/src/recordkey.ts`.
#
# https://atproto.com/specs/record-key#record-key-syntax
# - allowed characters: alphanumeric (A-Za-z0-9), period, dash, underscore,
#   colon, tilde (.-_:~)
# - length: 1 to 512 characters
# - the values "." and ".." are not allowed

const RECORD_KEY_MAX_LEN = 512
const RECORD_KEY_MIN_LEN = 1
const RECORD_KEY_REGEX = r"\A[a-zA-Z0-9_~.:-]{1,512}\z"

"""
    is_valid_record_key(s) -> Bool

Return `true` if `s` is a valid record key (1–512 chars from
`A-Za-z0-9_~.:-`, excluding `"."` and `".."`).
"""
function is_valid_record_key(s::AbstractString)::Bool
    return RECORD_KEY_MIN_LEN <= length(s) <= RECORD_KEY_MAX_LEN &&
           occursin(RECORD_KEY_REGEX, s) && s != "." && s != ".."
end

"""
    ensure_valid_record_key(s) -> String

Validate that `s` is a valid record key, returning `s`, or throw
[`InvalidRecordKeyError`](@ref).
"""
function ensure_valid_record_key(s::AbstractString)::String
    if length(s) > RECORD_KEY_MAX_LEN || length(s) < RECORD_KEY_MIN_LEN
        throw(InvalidRecordKeyError(
            "record key must be $RECORD_KEY_MIN_LEN to $RECORD_KEY_MAX_LEN characters",
        ))
    end
    if s == "." || s == ".."
        throw(InvalidRecordKeyError("record key can not be \".\" or \"..\""))
    end
    if !occursin(RECORD_KEY_REGEX, s)
        throw(InvalidRecordKeyError("record key syntax not valid (regex)"))
    end
    return String(s)
end
