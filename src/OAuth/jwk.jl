# JSON Web Key (JWK) + ES256/ES256K JWT signing/verification.
# Port of `packages/oauth/jwk` + `jwk-jose` (essential paths).

"""
    jwk_public_key(key::AbstractEcKey) -> Dict

Export a public key as a JWK (JSON Web Key) dict:
`{"kty" => "EC", "crv" => "P-256"|"secp256k1", "x" => ..., "y" => ...}`
with base64url-encoded coordinates.
"""
function jwk_public_key(key::T) where {T<:AbstractEcKey}
    pub = public_key_bytes(key)  # uncompressed: 0x04 ‖ x ‖ y
    x = pub[2:33]
    y = pub[34:65]
    crv = jwt_alg(key) == "ES256" ? "P-256" : "secp256k1"
    return Dict{String,Any}(
        "kty" => "EC",
        "crv" => crv,
        "x" => base64url_encode(x),
        "y" => base64url_encode(y),
    )
end

"The bare public JWK (no private key material), used in DPoP headers."
jwk_public_key(key::P256Key) = Dict{String,Any}(
    "kty" => "EC",
    "crv" => "P-256",
    "x" => base64url_encode(public_key_bytes(key)[2:33]),
    "y" => base64url_encode(public_key_bytes(key)[34:65]),
)

jwk_public_key(key::Secp256k1Key) = Dict{String,Any}(
    "kty" => "EC",
    "crv" => "secp256k1",
    "x" => base64url_encode(public_key_bytes(key)[2:33]),
    "y" => base64url_encode(public_key_bytes(key)[34:65]),
)

"""
    jwk_thumbprint(jwk::Dict) -> String

RFC 7638 JWK thumbprint: base64url(SHA-256(canonical JSON of required members)).
For EC keys: crv, kty, x, y (sorted).
"""
function jwk_thumbprint(jwk::AbstractDict)
    kty = jwk["kty"]
    components = if kty == "EC"
        Dict{String,Any}("crv" => jwk["crv"], "kty" => jwk["kty"],
                         "x" => jwk["x"], "y" => jwk["y"])
    elseif kty == "RSA"
        Dict{String,Any}("e" => jwk["e"], "kty" => jwk["kty"], "n" => jwk["n"])
    else
        throw(ArgumentError("unsupported kty: $kty"))
    end
    # RFC 7638: no whitespace, sorted keys
    json = join(["$(JSON.json(k))=$(JSON.json(v))" for (k, v) in sort(collect(pairs(components)); by = first)], ",")
    json = "{" * json * "}"
    return base64url_encode(sha256(json))
end

# --- JWT (compact JWS with ES256/ES256K) --------------------------------------

_base64url_json(value) = base64url_encode(Vector{UInt8}(codeunits(JSON.json(value))))

"""
    sign_jwt_es256(key::P256Key, header::Dict, payload::Dict) -> String

Create a signed JWT (compact JWS) using ES256 (P-256 + SHA-256).
The signature is 64 raw bytes (r ‖ s) base64url-encoded.
"""
function sign_jwt_es256(key::P256Key, header::Dict, payload::Dict)::String
    h = _base64url_json(header)
    p = _base64url_json(payload)
    signing_input = h * "." * p
    digest = sha256(signing_input)
    sig = sign_digest(key, digest)  # 64-byte compact r||s, low-S
    return signing_input * "." * base64url_encode(sig)
end

"""
    sign_jwt_es256k(key::Secp256k1Key, header::Dict, payload::Dict) -> String

Create a signed JWT (compact JWS) using ES256K (secp256k1 + SHA-256).
"""
function sign_jwt_es256k(key::Secp256k1Key, header::Dict, payload::Dict)::String
    h = _base64url_json(header)
    p = _base64url_json(payload)
    signing_input = h * "." * p
    digest = sha256(signing_input)
    sig = sign_digest(key, digest)
    return signing_input * "." * base64url_encode(sig)
end

"Decode a JWT's header and payload (no verification)."
function jwt_decode(token::AbstractString)
    parts = split(token, '.')
    length(parts) == 3 || throw(ArgumentError("not a compact JWT"))
    header = JSON.parse(String(base64url_decode(String(parts[1]))))
    payload = JSON.parse(String(base64url_decode(String(parts[2]))))
    return (header = header, payload = payload, signature = base64url_decode(String(parts[3])))
end

"""
    verify_jwt_es256k(token, public_key_bytes) -> Bool

Verify an ES256K JWT (compact JWS): SHA-256 of the signing input, 64-byte
compact signature, checked against the secp256k1 public key.
"""
function verify_jwt_es256k(token::AbstractString,
                           pub_key_bytes::AbstractVector{UInt8})::Bool
    parts = split(token, '.')
    length(parts) == 3 || return false
    sig = try
        base64url_decode(String(parts[3]))
    catch
        return false
    end
    length(sig) == 64 || return false
    digest = sha256(String(parts[1]) * "." * String(parts[2]))
    return verify_sig_digest(pub_key_bytes, digest, sig; jwt_alg = "ES256K")
end

"Verify an ES256 JWT against a P-256 public key."
function verify_jwt_es256(token::AbstractString,
                          pub_key_bytes::AbstractVector{UInt8})::Bool
    parts = split(token, '.')
    length(parts) == 3 || return false
    sig = try
        base64url_decode(String(parts[3]))
    catch
        return false
    end
    length(sig) == 64 || return false
    digest = sha256(String(parts[1]) * "." * String(parts[2]))
    return verify_sig_digest(pub_key_bytes, digest, sig; jwt_alg = "ES256")
end
