module Crypto

using SHA
using Base64
using OpenSSL
using OpenSSL_jll: libcrypto

export ATProtoCryptoError,
    InvalidMultibaseError,
    InvalidCidError,
    InvalidMultikeyError,
    UnsupportedKeyTypeError,
    varint_encode,
    varint_decode,
    read_varint,
    base16_encode,
    base16upper_encode,
    base16_decode,
    base32_encode,
    base32upper_encode,
    base32_decode,
    base58btc_encode,
    base58btc_decode,
    base64_encode,
    base64pad_encode,
    base64url_encode,
    base64urlpad_encode,
    base64_decode,
    base64pad_decode,
    base64url_decode,
    base64urlpad_decode,
    multibase_to_bytes,
    bytes_to_multibase,
    sha256,
    sha256hex,
    sha256_multihash,
    identity_multihash,
    CID,
    cid_parse,
    cid_from_bytes,
    cid_bytes,
    cid_for_dagcbor,
    cid_codec_name,
    DAG_CBOR_CODEC,
    RAW_CODEC,
    DAG_PB_CODEC,
    parse_did_key,
    format_did_key,
    parse_multikey,
    format_multikey,
    P256_DID_PREFIX,
    SECP256K1_DID_PREFIX,
    compress_pubkey,
    decompress_pubkey,
    AbstractEcKey,
    P256Key,
    Secp256k1Key,
    generate_key,
    import_key,
    public_key_bytes,
    private_key_bytes,
    jwt_alg,
    did_key,
    sign_message,
    sign_digest,
    verify_sig,
    verify_did_sig,
    random_bytes,
    MULTICODEC_MULTIKEY,
    MULTICODEC_SECP256K1_PUB

include("errors.jl")
include("varint.jl")
include("base_n.jl")
include("multibase.jl")
include("digest.jl")
include("cid.jl")
include("didkey.jl")
include("ecc.jl")

end # module
