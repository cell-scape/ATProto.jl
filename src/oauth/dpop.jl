# DPoP (Demonstrating Proof of Possession) — RFC 9449.
# Port of `packages/oauth/oauth-client/src/fetch-dpop.ts`.

"""
    build_dpop_proof(key, method, url; nonce=nothing, access_token=nothing) -> String

Build a DPoP proof JWT (RFC 9449 §4.2) for an HTTP request. The proof is
bound to the HTTP method (`htm`), the target URI without query/fragment
(`htu`), an optional server nonce, and the base64url hash of the access
token (`ath`) when present.

Returns a compact JWT signed with the key's algorithm (ES256 or ES256K).
"""
function build_dpop_proof(key::P256Key, method::AbstractString, url::AbstractString;
                          nonce::Union{AbstractString,Nothing} = nothing,
                          access_token::Union{AbstractString,Nothing} = nothing)::String
    header = Dict{String,Any}(
        "typ" => "dpop+jwt",
        "alg" => "ES256",
        "jwk" => jwk_public_key(key),
    )
    payload = Dict{String,Any}(
        "htu" => _build_htu(url),
        "htm" => uppercase(String(method)),
        "iat" => Int(floor(time())),
        "jti" => generate_nonce(12),
    )
    nonce === nothing || (payload["nonce"] = String(nonce))
    access_token === nothing ||
        (payload["ath"] = base64url_encode(sha256(String(access_token))))
    return sign_jwt_es256(key, header, payload)
end

function build_dpop_proof(key::Secp256k1Key, method::AbstractString, url::AbstractString;
                          nonce::Union{AbstractString,Nothing} = nothing,
                          access_token::Union{AbstractString,Nothing} = nothing)::String
    header = Dict{String,Any}(
        "typ" => "dpop+jwt",
        "alg" => "ES256K",
        "jwk" => jwk_public_key(key),
    )
    payload = Dict{String,Any}(
        "htu" => _build_htu(url),
        "htm" => uppercase(String(method)),
        "iat" => Int(floor(time())),
        "jti" => generate_nonce(12),
    )
    nonce === nothing || (payload["nonce"] = String(nonce))
    access_token === nothing ||
        (payload["ath"] = base64url_encode(sha256(String(access_token))))
    return sign_jwt_es256k(key, header, payload)
end

"""
    generate_dpop_key(; alg="ES256K")

Generate a fresh DPoP key. atproto primarily uses ES256K (secp256k1);
ES256 (P-256) is the fallback per the spec.
"""
generate_dpop_key(; alg::AbstractString = "ES256K") =
    alg == "ES256" ? generate_key(P256Key) : generate_key(Secp256k1Key)

"The `htu` (HTTP target URI) claim: scheme + authority + path, no query/fragment."
function _build_htu(url::AbstractString)::String
    # strip query and fragment
    u = String(url)
    q = findfirst('?', u)
    f = findfirst('#', u)
    cut = q === nothing ? (f === nothing ? nothing : f) :
          (f === nothing ? q : min(q, f))
    cut === nothing && return u
    return u[1:prevind(u, cut)]
end
