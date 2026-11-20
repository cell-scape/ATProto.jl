# Multibase: prefix-character dispatch over the base codecs.
# Port of `packages/crypto/src/multibase.ts` (plus the standard `M` prefix).

"""
    multibase_to_bytes(mb::AbstractString) -> Vector{UInt8}

Decode a multibase-prefixed string (first character selects the encoding) to
bytes. Supported prefixes: `f`/`F` (base16), `b`/`B` (base32), `z`
(base58btc), `m`/`M` (base64), `u`/`U` (base64url). Throws
[`InvalidMultibaseError`](@ref) on an unsupported prefix or bad payload.
"""
function multibase_to_bytes(mb::AbstractString)::Vector{UInt8}
    isempty(mb) && throw(InvalidMultibaseError("empty multibase string"))
    base = first(mb)
    payload = SubString(mb, nextind(mb, 1):lastindex(mb))
    try
        base == 'f' && return base16_decode(payload)
        base == 'F' && return base16_decode(payload)
        base == 'b' && return base32_decode(payload)
        base == 'B' && return base32_decode(payload)
        base == 'z' && return base58btc_decode(payload)
        base == 'm' && return base64_decode(payload)
        base == 'M' && return base64pad_decode(payload)
        base == 'u' && return base64url_decode(payload)
        base == 'U' && return base64urlpad_decode(payload)
    catch err
        err isa ArgumentError || rethrow()
        throw(InvalidMultibaseError("invalid multibase payload: $(err.msg)"))
    end
    throw(InvalidMultibaseError("unsupported multibase prefix: $base"))
end

"""
    bytes_to_multibase(bytes; encoding::Symbol=:base58btc) -> String

Encode bytes to a multibase-prefixed string. `encoding` is one of `:base16`,
`:base16upper`, `:base32`, `:base32upper`, `:base58btc`, `:base64`,
`:base64pad`, `:base64url`, `:base64urlpad`.
"""
function bytes_to_multibase(bytes::AbstractVector{UInt8}; encoding::Symbol = :base58btc)::String
    enc = encoding
    enc == :base16 && return "f" * base16_encode(bytes)
    enc == :base16upper && return "F" * base16upper_encode(bytes)
    enc == :base32 && return "b" * base32_encode(bytes)
    enc == :base32upper && return "B" * base32upper_encode(bytes)
    enc == :base58btc && return "z" * base58btc_encode(bytes)
    enc == :base64 && return "m" * base64_encode(bytes)
    enc == :base64pad && return "M" * base64pad_encode(bytes)
    enc == :base64url && return "u" * base64url_encode(bytes)
    enc == :base64urlpad && return "U" * base64urlpad_encode(bytes)
    throw(InvalidMultibaseError("unsupported multibase encoding: $encoding"))
end
