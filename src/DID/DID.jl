module DID

using ..Crypto
using ..DagCbor
using HTTP
using JSON

export ATProtoDidError,
    DidNotFoundError,
    PoorlyFormattedDidError,
    PoorlyFormattedDidDocumentError,
    UnsupportedDidMethodError,
    UnsupportedDidWebPathError,
    is_did_plc,
    ensure_did_plc,
    is_did_web,
    ensure_did_web,
    is_atproto_did,
    ensure_atproto_did,
    did_web_to_url,
    build_did_web_url,
    DidDocument,
    DidService,
    DidVerificationMethod,
    parse_did_document,
    get_did,
    get_handle,
    get_signing_key,
    get_pds_endpoint,
    get_notif_endpoint,
    get_feed_gen_endpoint,
    AtprotoData,
    parse_to_atproto_document,
    ensure_atproto_data,
    DidMemoryCache,
    cache_did!,
    check_cache,
    clear_entry!,
    clear!,
    CacheResult,
    PlcResolver,
    WebResolver,
    DidResolver,
    resolve,
    resolve_document,
    ensure_resolve,
    resolve_atproto_data,
    resolve_atproto_key,
    verify_signature,
    PlcClient,
    get_document,
    get_last_operation,
    get_audit_log,
    get_ops,
    plc_genesis_did,
    verify_legacy_create,
    verify_operation

include("errors.jl")
include("validation.jl")
include("document.jl")
include("atproto_data.jl")
include("cache.jl")
include("resolver.jl")
include("plc.jl")

end # module
