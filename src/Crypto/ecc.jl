# ECDSA keys & signatures over P-256 and secp256k1 via libcrypto (OpenSSL 3).
# Mirrors `packages/crypto/src/{p256,secp256k1}` in the TS reference:
#   - messages are hashed with SHA-256 before signing/verifying
#   - signatures are 64-byte compact (r||s), low-S normalized
#   - public keys use 65-byte uncompressed / 33-byte compressed SEC1 forms

# --- curve registry -----------------------------------------------------------

const NID_P256 = Cint(415)      # NID_X9_62_prime256v1
const NID_SECP256K1 = Cint(714) # NID_secp256k1

const P256_ORDER_HEX = "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"
const SECP256K1_ORDER_HEX = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"

# cross-check the secp256k1 order against its well-known value
@assert parse(BigInt, SECP256K1_ORDER_HEX; base = 16) == BigInt(2)^256 - parse(BigInt, "14551231950B75FC4402DA1732FC9BEBF"; base = 16)

# half-order (n >> 1) as fixed 32-byte big-endian, for low-S checks
_half_order_hex(order_hex::String) =
    lpad(string(div(parse(BigInt, order_hex; base = 16), 2); base = 16), 64, '0')

const _CURVES = IdDict{Symbol,NamedTuple}(
    :p256 => (nid = NID_P256, jwt_alg = "ES256", order_hex = P256_ORDER_HEX,
              half_order = hex2bytes(_half_order_hex(P256_ORDER_HEX))),
    :secp256k1 => (nid = NID_SECP256K1, jwt_alg = "ES256K", order_hex = SECP256K1_ORDER_HEX,
                   half_order = hex2bytes(_half_order_hex(SECP256K1_ORDER_HEX))),
)

_curve(jwt_alg::AbstractString) =
    jwt_alg == "ES256" ? _CURVES[:p256] :
    jwt_alg == "ES256K" ? _CURVES[:secp256k1] :
    throw(UnsupportedKeyTypeError("unsupported key type: $jwt_alg"))

# --- libcrypto bindings ---------------------------------------------------------

for (f, ret, types) in (
    (:EC_KEY_new_by_curve_name, Ptr{Cvoid}, (Cint,)),
    (:EC_KEY_free, Cvoid, (Ptr{Cvoid},)),
    (:EC_KEY_generate_key, Cint, (Ptr{Cvoid},)),
    (:EC_KEY_get0_group, Ptr{Cvoid}, (Ptr{Cvoid},)),
    (:EC_KEY_set_private_key, Cint, (Ptr{Cvoid}, Ptr{Cvoid})),
    (:EC_KEY_get0_private_key, Ptr{Cvoid}, (Ptr{Cvoid},)),
    (:EC_KEY_set_public_key, Cint, (Ptr{Cvoid}, Ptr{Cvoid})),
    (:EC_KEY_get0_public_key, Ptr{Cvoid}, (Ptr{Cvoid},)),
    (:EC_POINT_new, Ptr{Cvoid}, (Ptr{Cvoid},)),
    (:EC_POINT_free, Cvoid, (Ptr{Cvoid},)),
    (:EC_POINT_mul, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
    (:EC_POINT_oct2point, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Cvoid})),
    (:ECDSA_do_sign, Ptr{Cvoid}, (Ptr{UInt8}, Cint, Ptr{Cvoid})),
    (:ECDSA_do_verify, Cint, (Ptr{UInt8}, Cint, Ptr{Cvoid}, Ptr{Cvoid})),
    (:ECDSA_SIG_new, Ptr{Cvoid}, ()),
    (:ECDSA_SIG_free, Cvoid, (Ptr{Cvoid},)),
    (:ECDSA_SIG_set0, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
    (:BN_new, Ptr{Cvoid}, ()),
    (:BN_clear_free, Cvoid, (Ptr{Cvoid},)),
    (:BN_bin2bn, Ptr{Cvoid}, (Ptr{UInt8}, Cint, Ptr{Cvoid})),
    (:BN_num_bits, Cint, (Ptr{Cvoid},)),
    (:BN_bn2bin, Cint, (Ptr{Cvoid}, Ptr{UInt8})),
    (:BN_cmp, Cint, (Ptr{Cvoid}, Ptr{Cvoid})),
    (:BN_sub, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
    (:BN_CTX_new, Ptr{Cvoid}, ()),
    (:BN_CTX_free, Cvoid, (Ptr{Cvoid},)),
)
    # NOTE: ccall is a special form — it needs statically-known argument lists,
    # so we generate typed wrapper functions rather than vararg closures
    argtypes = Expr(:tuple, types...)
    fargs = [Symbol("x", i) for i in eachindex(types)]
    sigargs = [Expr(:(::), fargs[i], types[i]) for i in eachindex(types)]
    @eval function $f($(sigargs...))
        return ccall(($(QuoteNode(f)), libcrypto), $ret, $argtypes, $(fargs...))
    end
end

# ECDSA_SIG_get0 (out-params)
function _sig_get0(sig::Ptr{Cvoid})::Tuple{Ptr{Cvoid},Ptr{Cvoid}}
    pr = Ref{Ptr{Cvoid}}(C_NULL)
    ps = Ref{Ptr{Cvoid}}(C_NULL)
    ccall((:ECDSA_SIG_get0, libcrypto), Cvoid, (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Ptr{Ptr{Cvoid}}), sig, pr, ps)
    return (pr[], ps[])
end

# EC_POINT_point2oct with output form
const _POINT_FORM_COMPRESSED = Cint(2)
const _POINT_FORM_UNCOMPRESSED = Cint(4)

function _point2oct(group::Ptr{Cvoid}, point::Ptr{Cvoid}, form::Cint,
                    ctx::Ptr{Cvoid})::Vector{UInt8}
    buf = Vector{UInt8}(undef, 65)
    len = ccall((:EC_POINT_point2oct, libcrypto), Csize_t,
                (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}),
                group, point, form, buf, sizeof(buf), ctx)
    len == 0 && error("EC_POINT_point2oct failed")
    return buf[1:len]
end

function _bn_to_bytes32(bn::Ptr{Cvoid})::Vector{UInt8}
    n = Int(BN_num_bits(bn))
    nbytes = cld(n, 8)
    nbytes == 0 && return zeros(UInt8, 32)
    nbytes > 32 && error("BIGNUM too large for fixed 32-byte scalar")
    buf = zeros(UInt8, 32)
    BN_bn2bin(bn, pointer(buf, 33 - nbytes))
    return buf
end

function _bn_from_bytes(bytes::AbstractVector{UInt8})::Ptr{Cvoid}
    bn = BN_bin2bn(pointer(bytes), Cint(length(bytes)), C_NULL)
    bn == C_NULL && error("BN_bin2bn failed")
    return bn
end

# --- key types ------------------------------------------------------------------

"""
    AbstractEcKey

Supertype of [`P256Key`](@ref) and [`Secp256k1Key`](@ref) — mutable wrappers
around a libcrypto `EC_KEY*`, freed by a finalizer.
"""
abstract type AbstractEcKey end

"""
    P256Key

A P-256 (prime256v1 / ES256) ECDSA keypair or public key. See
[`generate_key`](@ref), [`import_key`](@ref).
"""
mutable struct P256Key <: AbstractEcKey
    ptr::Ptr{Cvoid}
    function P256Key(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
        k = new(ptr)
        finalizer(k) do key
            key.ptr != C_NULL && EC_KEY_free(key.ptr)
            return
        end
        return k
    end
end

"""
    Secp256k1Key

A secp256k1 (ES256K) ECDSA keypair or public key. See [`generate_key`](@ref),
[`import_key`](@ref).
"""
mutable struct Secp256k1Key <: AbstractEcKey
    ptr::Ptr{Cvoid}
    function Secp256k1Key(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
        k = new(ptr)
        finalizer(k) do key
            key.ptr != C_NULL && EC_KEY_free(key.ptr)
            return
        end
        return k
    end
end

_curve_sym(::Type{P256Key}) = :p256
_curve_sym(::Type{Secp256k1Key}) = :secp256k1

"""
    generate_key(::Type{K}) where {K<:AbstractEcKey} -> K

Generate a fresh random keypair (`P256Key` or `Secp256k1Key`) using OpenSSL.
"""
function generate_key(::Type{K}) where {K<:AbstractEcKey}
    info = _CURVES[_curve_sym(K)]
    ptr = EC_KEY_new_by_curve_name(info.nid)
    ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
    key = K(ptr)
    EC_KEY_generate_key(key.ptr) == 1 || error("EC_KEY_generate_key failed")
    return key
end

"""
    import_key(::Type{K}, private_key) -> K where {K<:AbstractEcKey}

Import a 32-byte (or 64-char hex) private key and derive its public key.
"""
function import_key(::Type{K}, private_key::Union{AbstractVector{UInt8},AbstractString}) where {K<:AbstractEcKey}
    bytes = private_key isa AbstractString ? hex2bytes(private_key) : copy(private_key)
    length(bytes) == 32 || throw(ArgumentError("private key must be 32 bytes"))
    all(iszero, bytes) && throw(ArgumentError("private key must be non-zero"))
    info = _CURVES[_curve_sym(K)]
    ptr = EC_KEY_new_by_curve_name(info.nid)
    ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
    key = K(ptr)
    bn = C_NULL
    ctx = C_NULL
    try
        bn = _bn_from_bytes(bytes)
        EC_KEY_set_private_key(key.ptr, bn) == 1 || error("EC_KEY_set_private_key failed")
        group = EC_KEY_get0_group(key.ptr)
        pub = EC_POINT_new(group)
        ctx = BN_CTX_new()
        # derive public key: pub = priv * G
        EC_POINT_mul(group, pub, bn, C_NULL, C_NULL, ctx) == 1 ||
            error("EC_POINT_mul failed")
        EC_KEY_set_public_key(key.ptr, pub) == 1 || error("EC_KEY_set_public_key failed")
        EC_POINT_free(pub)
    finally
        bn != C_NULL && BN_clear_free(bn)
        ctx != C_NULL && BN_CTX_free(ctx)
    end
    return key
end

"""
    public_key_bytes(key) -> Vector{UInt8}

The uncompressed SEC1 public key (65 bytes: `0x04 ‖ X ‖ Y`).
"""
function public_key_bytes(key::AbstractEcKey)::Vector{UInt8}
    group = EC_KEY_get0_group(key.ptr)
    pub = EC_KEY_get0_public_key(key.ptr)
    pub == C_NULL && error("key has no public key")
    ctx = BN_CTX_new()
    try
        return _point2oct(group, pub, _POINT_FORM_UNCOMPRESSED, ctx)
    finally
        BN_CTX_free(ctx)
    end
end

"""
    private_key_bytes(key) -> Union{Vector{UInt8}, Nothing}

The 32-byte private key, or `nothing` if the key only holds a public key.
"""
function private_key_bytes(key::AbstractEcKey)::Union{Vector{UInt8},Nothing}
    bn = EC_KEY_get0_private_key(key.ptr)
    bn == C_NULL && return nothing
    return _bn_to_bytes32(bn)
end

"JWT algorithm identifier for the key's curve: `\"ES256\"` or `\"ES256K\"`."
jwt_alg(key::AbstractEcKey)::String = _CURVES[_curve_sym(typeof(key))].jwt_alg

"""
    did_key(key) -> String

The `did:key:z...` DID for this key's public key (matching `formatDidKey`).
"""
did_key(key::AbstractEcKey)::String = format_did_key(jwt_alg(key), public_key_bytes(key))

# --- signature operations ---------------------------------------------------------

"""
    sign_digest(key, digest) -> Vector{UInt8}

Sign a 32-byte digest with ECDSA, returning the 64-byte compact signature
(r‖s), low-S normalized.
"""
function sign_digest(key::AbstractEcKey, digest::AbstractVector{UInt8})::Vector{UInt8}
    length(digest) == 32 || throw(ArgumentError("digest must be 32 bytes"))
    sig = ECDSA_do_sign(pointer(digest), Cint(32), key.ptr)
    sig == C_NULL && error("ECDSA_do_sign failed")
    r_bn = C_NULL
    s_bn = C_NULL
    n_bn = C_NULL
    half_bn = C_NULL
    diff_bn = C_NULL
    try
        (r_bn, s_bn) = _sig_get0(sig)
        # low-S normalization: if s > n/2, use n - s
        info = _CURVES[_curve_sym(typeof(key))]
        n_bn = _bn_from_bytes(hex2bytes(info.order_hex))
        half_bn = _bn_from_bytes(info.half_order)
        if BN_cmp(s_bn, half_bn) == 1
            diff_bn = BN_new()
            BN_sub(diff_bn, n_bn, s_bn) == 1 || error("BN_sub failed")
            s_bn = diff_bn
        end
        r = _bn_to_bytes32(r_bn)
        s = _bn_to_bytes32(s_bn)
        return vcat(r, s)
    finally
        sig != C_NULL && ECDSA_SIG_free(sig)  # r/s BNs are internal, freed with sig
        n_bn != C_NULL && BN_clear_free(n_bn)
        half_bn != C_NULL && BN_clear_free(half_bn)
        # diff_bn is our own BIGNUM (never adopted by sig), safe to free here
        diff_bn != C_NULL && BN_clear_free(diff_bn)
    end
end

"""
    sign_message(key, msg) -> Vector{UInt8}

SHA-256 hash `msg` and sign the digest (as in the TS reference):
64-byte compact, low-S signature.
"""
sign_message(key::AbstractEcKey, msg::Union{AbstractVector{UInt8},AbstractString})::Vector{UInt8} =
    sign_digest(key, sha256(msg))

"""Build a public-only EC_KEY for verification."""
function _pub_key(::Type{K}, pub_bytes::AbstractVector{UInt8}) where {K<:AbstractEcKey}
    info = _CURVES[_curve_sym(K)]
    ptr = EC_KEY_new_by_curve_name(info.nid)
    ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
    key = K(ptr)
    group = EC_KEY_get0_group(key.ptr)
    point = EC_POINT_new(group)
    ctx = BN_CTX_new()
    try
        ok = ccall((:EC_POINT_oct2point, libcrypto), Cint,
                   (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Cvoid}),
                   group, point, pointer(pub_bytes), Csize_t(length(pub_bytes)), ctx)
        ok == 1 || throw(ArgumentError("invalid public key point"))
        EC_KEY_set_public_key(key.ptr, point) == 1 || error("EC_KEY_set_public_key failed")
    finally
        EC_POINT_free(point)
        BN_CTX_free(ctx)
    end
    return key
end

"""
    verify_sig_digest(public_key, digest, sig; jwt_alg, allow_malleable=false) -> Bool

Verify a compact ECDSA signature over an already-computed 32-byte digest
(the prehashed counterpart to [`verify_sig`](@ref)).
"""
function verify_sig_digest(public_key::AbstractVector{UInt8}, digest::AbstractVector{UInt8},
                           sig::AbstractVector{UInt8}; jwt_alg::AbstractString,
                           allow_malleable::Bool = false)::Bool
    length(digest) == 32 || return false
    info = _curve(jwt_alg)
    strict = !allow_malleable
    if strict
        length(sig) == 64 || return false
        s = sig[33:64]
        s <= info.half_order || return false
    end
    return _verify_digest_raw(public_key, digest, sig, jwt_alg)
end

function _verify_digest_raw(public_key::AbstractVector{UInt8}, digest::AbstractVector{UInt8},
                            sig::AbstractVector{UInt8}, jwt_alg::AbstractString)::Bool
    K = jwt_alg == "ES256" ? P256Key : Secp256k1Key
    key = try
        _pub_key(K, public_key)
    catch
        return false
    end
    r_bn = C_NULL
    s_bn = C_NULL
    ec_sig = C_NULL
    try
        r_bn = _bn_from_bytes(sig[1:32])
        s_bn = _bn_from_bytes(sig[33:end])
        ec_sig = ECDSA_SIG_new()
        ECDSA_SIG_set0(ec_sig, r_bn, s_bn) == 1 || error("ECDSA_SIG_set0 failed")
        r_bn = C_NULL
        s_bn = C_NULL
        return ECDSA_do_verify(pointer(digest), Cint(32), ec_sig, key.ptr) == 1
    catch
        return false
    finally
        ec_sig != C_NULL && ECDSA_SIG_free(ec_sig)
        r_bn != C_NULL && BN_clear_free(r_bn)
        s_bn != C_NULL && BN_clear_free(s_bn)
    end
end

"""
    verify_sig(public_key, msg, sig; jwt_alg, allow_malleable=false) -> Bool

Verify a compact ECDSA signature of `msg` (SHA-256 hashed) against a public
key. Strict by default: exactly 64-byte compact signatures and low-S values.
`jwt_alg` is `"ES256"` (P-256) or `"ES256K"` (secp256k1).
"""
function verify_sig(public_key::AbstractVector{UInt8}, msg::AbstractVector{UInt8},
                    sig::AbstractVector{UInt8}; jwt_alg::AbstractString,
                    allow_malleable::Bool = false)::Bool
    info = _curve(jwt_alg)
    strict = !allow_malleable
    if strict
        length(sig) == 64 || return false
        s = sig[33:64]
        s <= info.half_order || return false
    end
    return _verify_digest_raw(public_key, sha256(msg), sig, jwt_alg)
end

"""
    verify_did_sig(did_key, msg, sig; allow_malleable=false) -> Bool

Verify a compact signature against a `did:key:z...` public key. Dispatches to
the right curve based on the multikey prefix.
"""
function verify_did_sig(did_key::AbstractString, msg::AbstractVector{UInt8},
                        sig::AbstractVector{UInt8}; allow_malleable::Bool = false)::Bool
    parsed = parse_did_key(did_key)
    return verify_sig(parsed.key_bytes, msg, sig;
                      jwt_alg = parsed.jwt_alg, allow_malleable = allow_malleable)
end

# --- point (de)compression ---------------------------------------------------------

function _point_recode(key_bytes::AbstractVector{UInt8}; from_form::Cint, to_form::Cint,
                       jwt_alg::AbstractString)::Vector{UInt8}
    info = _curve(jwt_alg)
    ptr = EC_KEY_new_by_curve_name(info.nid)
    ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
    group = EC_KEY_get0_group(ptr)
    point = EC_POINT_new(group)
    ctx = BN_CTX_new()
    try
        ok = ccall((:EC_POINT_oct2point, libcrypto), Cint,
                   (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}),
                   group, point, pointer(key_bytes), Csize_t(length(key_bytes)), ctx)
        ok == 1 || throw(ArgumentError("invalid public key point"))
        return _point2oct(group, point, to_form, ctx)
    finally
        EC_POINT_free(point)
        BN_CTX_free(ctx)
        EC_KEY_free(ptr)
    end
end

"""
    compress_pubkey(key_bytes; jwt_alg) -> Vector{UInt8}

Convert an uncompressed (65-byte) public key to compressed (33-byte) SEC1
form.
"""
compress_pubkey(key_bytes::AbstractVector{UInt8}; jwt_alg::AbstractString)::Vector{UInt8} =
    _point_recode(key_bytes; from_form = _POINT_FORM_UNCOMPRESSED,
                  to_form = _POINT_FORM_COMPRESSED, jwt_alg = jwt_alg)

"""
    decompress_pubkey(key_bytes; jwt_alg) -> Vector{UInt8}

Convert a compressed (33-byte) public key to uncompressed (65-byte) SEC1
form. Throws `ArgumentError` for anything that is not a valid point.
"""
function decompress_pubkey(key_bytes::AbstractVector{UInt8}; jwt_alg::AbstractString)::Vector{UInt8}
    length(key_bytes) == 33 ||
        throw(ArgumentError("expected 33 byte compressed pubkey"))
    return _point_recode(key_bytes; from_form = _POINT_FORM_COMPRESSED,
                         to_form = _POINT_FORM_UNCOMPRESSED, jwt_alg = jwt_alg)
end
