# Multiformats base encodings used by atproto. All codecs are unpadded where
# the multiformats spec says so, and operate on raw bytes.

# --- base16 (hex) ------------------------------------------------------------

"Encode bytes as lower-case hexadecimal."
base16_encode(bytes::AbstractVector{UInt8}) = bytes2hex(bytes)

"Encode bytes as upper-case hexadecimal."
base16upper_encode(bytes::AbstractVector{UInt8}) = uppercase(bytes2hex(bytes))

"Hex digit value, or throw for non-hex characters."
function _hex_digit(c::Char)::Int
    return if '0' <= c <= '9'
        Int(c - '0')
    elseif 'a' <= c <= 'f'
        Int(c - 'a' + 10)
    elseif 'A' <= c <= 'F'
        Int(c - 'A' + 10)
    else
        throw(ArgumentError("invalid base16 character: $c"))
    end
end

function base16_decode(s::AbstractString)::Vector{UInt8}
    iseven(length(s)) || throw(ArgumentError("invalid base16 length (must be even)"))
    out = Vector{UInt8}(undef, length(s) ÷ 2)
    i = 1
    for j in eachindex(out)
        out[j] = UInt8(_hex_digit(s[i]) << 4 | _hex_digit(s[nextind(s, i)]))
        i += 2
    end
    return out
end

# --- base32 (RFC 4648, no padding) --------------------------------------------

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"
const BASE32UPPER_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

function _base32_encode(bytes::AbstractVector{UInt8}, alphabet::String)::String
    buf = IOBuffer()
    acc = UInt32(0)
    bits = 0
    for b in bytes
        acc = (acc << 8) | b
        bits += 8
        while bits >= 5
            bits -= 5
            print(buf, alphabet[(Int((acc >> bits) & 0x1f)) + 1])
        end
    end
    if bits > 0
        print(buf, alphabet[(Int((acc << (5 - bits)) & 0x1f)) + 1])
    end
    return String(take!(buf))
end

function _base32_decode(s::AbstractString, alphabet::String)::Vector{UInt8}
    lookup = Dict(c => i - 1 for (i, c) in enumerate(alphabet))
    buf = IOBuffer()
    acc = UInt32(0)
    bits = 0
    for c in s
        d = get(lookup, c, nothing)
        d === nothing && throw(ArgumentError("invalid base32 character: $c"))
        acc = (acc << 5) | UInt32(d)
        bits += 5
        if bits >= 8
            bits -= 8
            write(buf, UInt8((acc >> bits) & 0xff))
        end
    end
    # trailing partial bits: multiformats tolerates non-canonical padding
    # bits (real-world CIDs carry them), so they are masked off here
    return take!(buf)
end

"Encode bytes as RFC 4648 lower-case base32 without padding (multibase `b`)."
base32_encode(bytes::AbstractVector{UInt8}) = _base32_encode(bytes, BASE32_ALPHABET)
"Encode bytes as RFC 4648 upper-case base32 without padding (multibase `B`)."
base32upper_encode(bytes::AbstractVector{UInt8}) = _base32_encode(bytes, BASE32UPPER_ALPHABET)
"Decode RFC 4648 lower/upper-case unpadded base32."
base32_decode(s::AbstractString) =
    _base32_decode(s, isnothing(findfirst(c -> isuppercase(c), s)) ? BASE32_ALPHABET : BASE32UPPER_ALPHABET)

# --- base58btc -----------------------------------------------------------------

const BASE58_BTC_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

"""
    base58btc_encode(bytes) -> String

Encode bytes in the Bitcoin base58 alphabet (multibase `z`).
"""
function base58btc_encode(bytes::AbstractVector{UInt8})::String
    isempty(bytes) && return ""
    n = BigInt(0)
    for b in bytes
        n = (n << 8) | b
    end
    out = Char[]
    while n > 0
        (n, d) = divrem(n, 58)
        pushfirst!(out, BASE58_BTC_ALPHABET[Int(d)+1])
    end
    # leading zero bytes encode as leading '1's
    for b in bytes
        b == 0x00 || break
        pushfirst!(out, '1')
    end
    return String(out)
end

"""
    base58btc_decode(s) -> Vector{UInt8}

Decode a Bitcoin-alphabet base58 string. Throws `ArgumentError` on invalid
characters.
"""
function base58btc_decode(s::AbstractString)::Vector{UInt8}
    isempty(s) && return UInt8[]
    n = BigInt(0)
    for c in s
        idx = findfirst(==(c), BASE58_BTC_ALPHABET)
        idx === nothing && throw(ArgumentError("invalid base58btc character: $c"))
        n = n * 58 + (idx - 1)
    end
    out = UInt8[]
    while n > 0
        (n, d) = divrem(n, 256)
        pushfirst!(out, UInt8(d))
    end
    for c in s  # leading '1's decode as zero bytes
        c == '1' || break
        pushfirst!(out, 0x00)
    end
    return out
end

# --- base64 variants ------------------------------------------------------------

_std_b64(s) = replace(s, '+' => "-", '/' => "_")
_url_b64(s) = replace(s, '-' => "+", '_' => "/")

"Standard alphabet, unpadded (multibase `m`)."
base64_encode(bytes) = rstrip(Base64.base64encode(bytes), '=')
"Standard alphabet, padded (multibase `M`)."
base64pad_encode(bytes) = Base64.base64encode(bytes)
"URL-safe alphabet, unpadded (multibase `u`)."
base64url_encode(bytes) = _std_b64(base64_encode(bytes))
"URL-safe alphabet, padded (multibase `U`)."
base64urlpad_encode(bytes) = _std_b64(Base64.base64encode(bytes))

function _b64_decode(s::AbstractString)::Vector{UInt8}
    t = String(s)
    # re-pad to a multiple of 4
    rem = length(t) % 4
    rem == 3 ? (t *= "=") : rem == 2 ? (t *= "==") :
    rem == 1 && throw(ArgumentError("invalid base64 length"))
    return Base64.base64decode(t)
end

"Decode standard-alphabet base64, with or without padding."
base64_decode(s) = _b64_decode(s)
"Decode standard-alphabet padded base64."
base64pad_decode(s) = Base64.base64decode(String(s))
"Decode URL-safe base64, with or without padding."
base64url_decode(s) = _b64_decode(_url_b64(s))
"Decode URL-safe padded base64."
base64urlpad_decode(s) = Base64.base64decode(_url_b64(String(s)))
