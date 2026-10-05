# PKCE (Proof Key for Code Exchange) — RFC 7636.
# Port of `packages/oauth/oauth-client/src/runtime.ts`.

"""
    generate_pkce(byte_length=32) -> NamedTuple

Generate a PKCE pair: `(verifier = "...", challenge = "...", method = "S256")`.
The verifier is a base64url-encoded random byte string (43-128 chars);
the challenge is the base64url-encoded SHA-256 of the verifier.
"""
function generate_pkce(byte_length::Int = 32)
    (32 <= byte_length <= 96) ||
        throw(ArgumentError("code_verifier length must be 32..96 bytes"))
    verifier_bytes = random_bytes(byte_length)
    verifier = base64url_encode(verifier_bytes)
    challenge = base64url_encode(sha256(verifier))
    return (verifier = verifier, challenge = challenge, method = "S256")
end

"Generate a random nonce (base64url-encoded random bytes)."
generate_nonce(byte_length::Int = 16) = base64url_encode(random_bytes(byte_length))
