# RIPEMD-160 (pure Julia). Used to derive did:plc identifiers from genesis
# operations. Verified against the official RIPEMD-160 test vectors.

# message selection (left line / right line), per the RIPEMD-160 spec
const _RMD_R1 = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                 7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
                 3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
                 1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
                 4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13)
const _RMD_R2 = (5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
                 6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
                 15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
                 8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
                 12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11)

# left rotations
const _RMD_S1 = (11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
                 7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
                 11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
                 11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
                 9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6)
const _RMD_S2 = (8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
                 9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
                 9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
                 15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
                 8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11)

const _RMD_K1 = (0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E)
const _RMD_K2 = (0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000)

@inline _f(j::Int, x::UInt32, y::UInt32, z::UInt32) =
    j < 16 ? (x ⊻ y ⊻ z) :
    j < 32 ? ((x & y) | (~x & z)) :
    j < 48 ? ((x | ~y) ⊻ z) :
    j < 64 ? ((x & z) | (y & ~z)) :
    (x ⊻ (y | ~z))

@inline _rol(x::UInt32, n::Int) = (x << n) | (x >> (32 - n))

"""
    ripemd160(data) -> Vector{UInt8}

RIPEMD-160 digest (20 bytes) of bytes or a UTF-8 string. Pure Julia,
validated against the official test vectors.
"""
function ripemd160(data::AbstractVector{UInt8})::Vector{UInt8}
    # padding: 0x80, zeros, 64-bit little-endian bit length
    bitlen = UInt64(length(data)) * 8
    msg = vcat(copy(data), UInt8(0x80))
    while length(msg) % 64 != 56
        push!(msg, 0x00)
    end
    lenbytes = UInt8[(bitlen >> (8 * i)) & 0xff for i in 0:7]
    append!(msg, lenbytes)

    h = UInt32[0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

    for block_start in 1:64:length(msg)
        x = Vector{UInt32}(undef, 16)
        for i in 0:15
            b = block_start + 4 * i
            x[i+1] = UInt32(msg[b]) | (UInt32(msg[b+1]) << 8) |
                     (UInt32(msg[b+2]) << 16) | (UInt32(msg[b+3]) << 24)
        end

        al, bl, cl, dl, el = h[1], h[2], h[3], h[4], h[5]
        ar, br, cr, dr, er = h[1], h[2], h[3], h[4], h[5]

        for j in 0:79
            round = j ÷ 16 + 1
            t = _rol(al + _f(j, bl, cl, dl) + x[_RMD_R1[j+1]+1] + _RMD_K1[round], _RMD_S1[j+1]) + el
            al, el, dl, cl, bl = el, dl, _rol(cl, 10), bl, t

            t = _rol(ar + _f(79 - j, br, cr, dr) + x[_RMD_R2[j+1]+1] + _RMD_K2[round], _RMD_S2[j+1]) + er
            ar, er, dr, cr, br = er, dr, _rol(cr, 10), br, t
        end

        # final recombination (0-indexed spec: h0' = h1 + C + D'; ...; h4' = h0 + B + C')
        t1 = h[2] + cl + dr
        t2 = h[3] + dl + er
        t3 = h[4] + el + ar
        t4 = h[5] + al + br
        t5 = h[1] + bl + cr
        h[1], h[2], h[3], h[4], h[5] = t1, t2, t3, t4, t5
    end

    out = Vector{UInt8}(undef, 20)
    for (i, w) in enumerate(h)  # little-endian words
        j = (i - 1) * 4
        out[j+1] = UInt8(w & 0xff)
        out[j+2] = UInt8((w >> 8) & 0xff)
        out[j+3] = UInt8((w >> 16) & 0xff)
        out[j+4] = UInt8((w >> 24) & 0xff)
    end
    return out
end

ripemd160(data::AbstractString) = ripemd160(collect(codeunits(data)))
