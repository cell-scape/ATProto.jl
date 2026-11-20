# secp256k1 public-key recovery from a recoverable ECDSA signature
# (SEC 1 §4.1.6), used to verify PLC `LegacyCreate` genesis operations.
# OpenSSL does not expose recovery directly, so it is implemented on top of
# libcrypto's EC_POINT arithmetic.

# extra bindings (see ecc.jl for the binding generator)
for (f, ret, types) in (
    (:EC_POINT_add, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
    (:EC_POINT_invert, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
    (:EC_POINT_is_on_curve, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
)
    argtypes = Expr(:tuple, types...)
    fargs = [Symbol("x", i) for i in eachindex(types)]
    sigargs = [Expr(:(::), fargs[i], types[i]) for i in eachindex(types)]
    @eval function $f($(sigargs...))
        return ccall(($(QuoteNode(f)), libcrypto), $ret, $argtypes, $(fargs...))
    end
end

# secp256k1 field prime p and order n (n is also in _CURVES)
const _SECP256K1_P_HEX = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F"

"""
    recover_pubkey(digest, sig65) -> Vector{UInt8}

Recover the uncompressed secp256k1 public key from a 65-byte recoverable
signature (`r ‖ s ‖ recovery_id`) over a 32-byte digest.

Throws `ArgumentError` for malformed signatures or an invalid recovery id
(matches libsecp256k1 behavior: no candidate key exists for the given id).
"""
function recover_pubkey(digest::AbstractVector{UInt8}, sig65::AbstractVector{UInt8})::Vector{UInt8}
    length(digest) == 32 || throw(ArgumentError("digest must be 32 bytes"))
    length(sig65) == 65 || throw(ArgumentError("recoverable signature must be 65 bytes"))
    recid = Int(sig65[65])
    0 <= recid <= 3 || throw(ArgumentError("invalid recovery id: $recid"))

    n = parse(BigInt, SECP256K1_ORDER_HEX; base = 16)
    p = parse(BigInt, _SECP256K1_P_HEX; base = 16)
    r = parse(BigInt, bytes2hex(sig65[1:32]); base = 16)
    s = parse(BigInt, bytes2hex(sig65[33:64]); base = 16)
    0 < r < n || throw(ArgumentError("invalid r value"))
    0 < s < n || throw(ArgumentError("invalid s value"))

    # R.x = r + (recid >> 1) * n, must be a valid field element
    x = r + (recid >> 1) * n
    x < p || throw(ArgumentError("invalid recovery id: sig.r + curve.n >= field prime"))

    # decompress R: 0x02|0x03 prefix selects y parity (recid & 1)
    x_bytes = hex2bytes(lpad(string(x; base = 16), 64, '0'))
    r_point_bytes = vcat(UInt8(0x02 | (recid & 1)), x_bytes)

    info = _CURVES[:secp256k1]
    key_ptr = EC_KEY_new_by_curve_name(info.nid)
    key_ptr == C_NULL && error("EC_KEY_new_by_curve_name failed")
    group = EC_KEY_get0_group(key_ptr)
    ctx = C_NULL
    r_point = C_NULL
    sr_point = C_NULL
    eg_point = C_NULL
    q_point = C_NULL
    try
        ctx = BN_CTX_new()
        r_point = EC_POINT_new(group)
        ok = ccall((:EC_POINT_oct2point, libcrypto), Cint,
                   (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Cvoid}),
                   group, r_point, pointer(r_point_bytes), Csize_t(33), ctx)
        ok == 1 || throw(ArgumentError("invalid recovery id: could not decompress R"))

        # e = digest (as big-endian integer) mod n
        e = parse(BigInt, bytes2hex(digest); base = 16) % n

        # sR = s * R
        s_bn = _bn_from_bytes(sig65[33:64])
        sr_point = EC_POINT_new(group)
        EC_POINT_mul(group, sr_point, C_NULL, r_point, s_bn, ctx) == 1 ||
            error("EC_POINT_mul (s*R) failed")

        # eG = e * G, then -eG
        e_bn = _bn_from_bytes(hex2bytes(lpad(string(e; base = 16), 64, '0')))
        eg_point = EC_POINT_new(group)
        EC_POINT_mul(group, eg_point, e_bn, C_NULL, C_NULL, ctx) == 1 ||
            error("EC_POINT_mul (e*G) failed")
        EC_POINT_invert(group, eg_point, ctx) == 1 || error("EC_POINT_invert failed")

        # sR - eG
        q_point = EC_POINT_new(group)
        EC_POINT_add(group, q_point, sr_point, eg_point, ctx) == 1 ||
            error("EC_POINT_add failed")

        # Q = r^-1 * (sR - eG)
        rinv = invmod(r, n)
        rinv_bn = _bn_from_bytes(hex2bytes(lpad(string(rinv; base = 16), 64, '0')))
        tmp = EC_POINT_new(group)
        try
            EC_POINT_mul(group, tmp, C_NULL, q_point, rinv_bn, ctx) == 1 ||
                error("EC_POINT_mul (r^-1) failed")
            return _point2oct(group, tmp, _POINT_FORM_UNCOMPRESSED, ctx)
        finally
            EC_POINT_free(tmp)
        end
    finally
        ctx != C_NULL && BN_CTX_free(ctx)
        r_point != C_NULL && EC_POINT_free(r_point)
        sr_point != C_NULL && EC_POINT_free(sr_point)
        eg_point != C_NULL && EC_POINT_free(eg_point)
        q_point != C_NULL && EC_POINT_free(q_point)
        key_ptr != C_NULL && EC_KEY_free(key_ptr)
    end
end
