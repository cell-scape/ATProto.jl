module ATProto

using Base64
using Dates
using HTTP
using JSON
using OpenSSL
using OpenSSL_jll
using Random
using SHA
using StructUtils
using URIs
using Unicode
using Zstd_jll

include("syntax/Syntax.jl")
include("crypto/Crypto.jl")
include("dagcbor/DagCbor.jl")
include("api/API.jl")
include("plc/PLC.jl")
include("identity/Identity.jl")
include("lexicon/Lexicon.jl")
include("repo/Repo.jl")
include("client/Client.jl")
include("richtext/RichText.jl")
include("oauth/OAuth.jl")
include("jetstream/Jetstream.jl")
include("lexicons.jl")

using .Syntax: ATProtoError, SyntaxError,
               Handle, DID, NSID, RecordKey, TID, ATDateTime, AtUri,
               @handle_str, @did_str, @nsid_str, @rkey_str, @tid_str, @at_str,
               is_valid_language, parse_language,
               is_valid_at_identifier, ensure_valid_at_identifier

using .Crypto: ATProtoCryptoError, InvalidMultibaseError, InvalidCidError,
               InvalidMultikeyError, UnsupportedKeyTypeError,
               varint_encode, varint_decode, read_varint,
               base16_encode, base16upper_encode, base16_decode,
               base32_encode, base32upper_encode, base32_decode,
               base58btc_encode, base58btc_decode,
               base64_encode, base64pad_encode, base64url_encode, base64urlpad_encode,
               base64_decode, base64pad_decode, base64url_decode, base64urlpad_decode,
               multibase_to_bytes, bytes_to_multibase,
               sha256, sha256hex, sha256_multihash, identity_multihash,
               CID, cid_parse, cid_from_bytes, cid_bytes, cid_for_dagcbor, cid_codec_name,
               DAG_CBOR_CODEC, RAW_CODEC, DAG_PB_CODEC,
               parse_did_key, format_did_key, parse_multikey, format_multikey,
               P256_DID_PREFIX, SECP256K1_DID_PREFIX,
               compress_pubkey, decompress_pubkey,
               AbstractEcKey, P256Key, Secp256k1Key,
               generate_key, import_key, public_key_bytes, private_key_bytes,
               jwt_alg, did_key, sign_message, sign_digest,
               verify_sig, verify_sig_digest, verify_did_sig,
               random_bytes, ripemd160, recover_pubkey,
               MULTICODEC_MULTIKEY, MULTICODEC_SECP256K1_PUB

using .DagCbor: DagBytes, dag_cbor_encode, dag_cbor_decode

using .API: LexiconModel, LexiconObject, LexiconRecord,
            LexiconMessage, LexiconParams, LexiconInput, LexiconOutput,
            CIDLink, ATBytes, BlobRef, UnknownObject,
            EndpointError, QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint,
            LEXICON_TYPES, LEXICON_ENDPOINTS, LEXICON_TOKENS,
            lexicon_type, needs_type_tag, record_key_type

using .PLC: ATProtoDidError, DidNotFoundError, PoorlyFormattedDidError,
            PoorlyFormattedDidDocumentError, UnsupportedDidMethodError,
            UnsupportedDidWebPathError,
            is_did_plc, ensure_did_plc, is_did_web, ensure_did_web,
            is_atproto_did, ensure_atproto_did,
            did_web_to_url, build_did_web_url,
            DidDocument, DidService, DidVerificationMethod,
            get_did, get_handle, get_signing_key,
            get_pds_endpoint, get_notif_endpoint, get_feed_gen_endpoint,
            AtprotoData, parse_to_atproto_document, ensure_atproto_data,
            DidMemoryCache, cache_did!, check_cache, clear_entry!, clear!, CacheResult,
            PlcResolver, WebResolver, DidResolver,
            resolve, resolve_document, ensure_resolve,
            resolve_atproto_data, resolve_atproto_key, verify_signature,
            PlcClient, get_document, get_last_operation, get_audit_log, get_ops,
            plc_genesis_did, verify_legacy_create, verify_operation

using .Identity: DEFAULT_PLC_URL, DEFAULT_DOH_URL,
                 IdentityError,
                 DIDVerificationMethod, DIDService, DIDDocument,
                 parse_did_document, pds_endpoint, atproto_handle, signing_key,
                 ResolvedIdentity, IdentityResolver, clear_cache!,
                 did_web_url, resolve_did, resolve_handle, verify_handle, resolve_identity

using .Lexicon: LexiconValidationError, InvalidLexiconError, LexiconDefNotFoundError,
                Lexicons, add_lexicon!, load_bundled_lexicons, get_def, get_def_or_throw,
                parse_lexicon_doc, to_lex_uri, validate_lex_ref_variant,
                assert_valid_record, assert_valid_xrpc_params,
                assert_valid_xrpc_input, assert_valid_xrpc_output,
                blob_ref_from_json, blob_ref_to_json, blob_ref_from_ipld, blob_ref_to_ipld

using .Repo: ATProtoRepoError, MissingBlockError,
             AbstractBlockStore, MemoryBlockStore, BlockMap,
             put_block!, put_blocks!, get_block, has_block, read_obj,
             Leaf, MST, leading_zeros_on_hash, is_valid_mst_key, ensure_valid_mst_key,
             mst_pointer, mst_create, mst_load, mst_add, mst_get, mst_update, mst_delete,
             mst_leaves, mst_list, mst_leaf_count, mst_get_layer!, mst_all_cids,
             mst_get_unstored_blocks, mst_cids_for_path, mst_equals,
             DataDiff, mst_diff,
             CarReader, read_car, write_car, write_car_v2, car_blocks,
             create_commit, load_commit, verify_commit_sig, verify_commit_chain

using .Client: DEFAULT_SERVICE, PUBLIC_APPVIEW, DEFAULT_CHAT_PROXY,
               XRPCError, AuthError,
               Session, RateLimitInfo, AtpAgent,
               service_url, session, is_authenticated, rate_limit,
               with_proxy, with_labelers, chat_agent,
               save_session, load_session,
               login!, refresh_session!, resume_session!, logout!,
               xrpc, xrpc_query, xrpc_procedure,
               XRPCPages, XRPCItems, eachpage, eachitem,
               get_profile, get_timeline, get_author_feed, get_post_thread,
               get_record, list_records, create_record, put_record, delete_record,
               upload_blob, post!,
               like!, unlike!, repost!, unrepost!,
               follow!, unfollow!, mute!, unmute!, block!, unblock!,
               reply_ref, reply!, quote_embed, quote_with_media_embed, quote_post!,
               external_embed, image_embed,
               get_notifications, get_unread_count, update_seen_notifications!,
               get_preferences, get_saved_feeds,
               get_bookmarks, create_bookmark!, delete_bookmark!,
               list_convos, get_convo_messages, send_chat_message!, update_convo_read!

using .RichText: RichTextDoc, RichTextSegment, RichTextBuilder,
                 add_text!, add_link!, add_mention!, add_tag!, build,
                 grapheme_length, byte_length, byte_slice,
                 detect_mentions, detect_links, detect_tags, detect_facets, richtext,
                 segments, is_mention, is_link, is_tag, mention_did, link_uri, tag_value

# Convenience overloads: publish RichTextDoc directly via post!, reply!, quote_post!, send_chat_message!
function Client.post!(
    agent::AtpAgent,
    rt::RichTextDoc;
    reply = nothing,
    embed = nothing,
    langs::Union{AbstractVector{<:AbstractString}, Nothing} = nothing,
    tags::Union{AbstractVector{<:AbstractString}, Nothing} = nothing,
    labels = nothing,
    createdAt::Union{ATDateTime, AbstractString} = ATDateTime(Dates.now(Dates.UTC)),
)
    facets = isempty(rt.facets) ? nothing : rt.facets
    return Client.post!(agent, rt.text; reply, embed, facets, langs, tags, labels, createdAt)
end

function Client.reply!(
    agent::AtpAgent,
    parent::API.AppBskyFeedDefsPostView,
    rt::RichTextDoc;
    root::Union{API.ComAtprotoRepoStrongRef, API.AppBskyFeedDefsPostView, Nothing} = nothing,
    kwargs...,
)
    facets = isempty(rt.facets) ? nothing : rt.facets
    return Client.reply!(agent, parent, rt.text; root, facets, kwargs...)
end

function Client.quote_post!(
    agent::AtpAgent,
    uri::Union{AtUri, AbstractString},
    cid::AbstractString,
    rt::RichTextDoc;
    media::Union{LexiconObject, Nothing} = nothing,
    kwargs...,
)
    facets = isempty(rt.facets) ? nothing : rt.facets
    return Client.quote_post!(agent, uri, cid, rt.text; media, facets, kwargs...)
end

Client.quote_post!(
    agent::AtpAgent,
    quoted::API.AppBskyFeedDefsPostView,
    rt::RichTextDoc;
    kwargs...,
) = Client.quote_post!(agent, quoted.uri, quoted.cid, rt; kwargs...)

function Client.send_chat_message!(
    agent::AtpAgent,
    convo_id::AbstractString,
    rt::RichTextDoc;
    embed = nothing,
)
    facets = isempty(rt.facets) ? nothing : rt.facets
    return Client.send_chat_message!(agent, convo_id, rt.text; facets, embed)
end

# Interop conversions between API wire primitives and Crypto/DagCbor types
Crypto.CID(link::CIDLink) = cid_parse(link.link)
API.CIDLink(c::CID) = CIDLink(string(c))
DagCbor.DagBytes(b::ATBytes) = DagBytes(b.data)
API.ATBytes(d::DagBytes) = ATBytes(copy(d.bytes))
DagCbor._encode!(io::IOBuffer, b::ATBytes) = DagCbor._encode!(io, DagBytes(b.data))
DagCbor._encode!(io::IOBuffer, link::CIDLink) = DagCbor._encode!(io, cid_parse(link.link))

using .OAuth: OAuthClientMetadata, OAuthSession,
              ServiceAuthError, ServiceAuthClaims,
              validate_client_metadata, generate_pkce, generate_dpop_key,
              build_dpop_proof,
              discover_authorization_server, pushed_authorization_request,
              build_par_authorization_url, build_authorization_url,
              exchange_code, refresh_token, oauth_request, oauth_transport,
              create_service_jwt, verify_service_jwt,
              sign_jwt_es256k, sign_jwt_es256, verify_jwt_es256k, verify_jwt_es256,
              jwt_decode, client_metadata_to_json, jwk_public_key, jwk_thumbprint

"""
    AtpAgent(oauth::OAuthSession, service::AbstractString=DEFAULT_SERVICE; kwargs...) -> AtpAgent

Construct an [`AtpAgent`](@ref) backed by a DPoP-bound [`OAuthSession`](@ref),
enabling all `xrpc`, pagination, and high-level social helpers over OAuth 2.1.
"""
function Client.AtpAgent(
    oauth::OAuthSession,
    service::AbstractString = DEFAULT_SERVICE;
    auto_pds::Bool = false,
    proxy::Union{AbstractString, Nothing} = nothing,
    labelers::AbstractVector{<:AbstractString} = String[],
    timeout::Real = 30.0,
)
    return AtpAgent(
        service;
        auto_pds = auto_pds,
        proxy = proxy,
        labelers = labelers,
        timeout = timeout,
        transport = oauth_transport(oauth),
    )
end

using .Jetstream: DEFAULT_JETSTREAM_URL, JETSTREAM_URLS,
                  JetstreamEvent, JetstreamCommitEvent, JetstreamIdentityEvent,
                  JetstreamAccountEvent, JetstreamUnknownEvent,
                  JetstreamStream,
                  ZstdDecompressor, zstd_compress, zstd_decompress,
                  save_cursor, load_cursor,
                  parse_jetstream_event, subscribe_jetstream, update_options!, last_cursor, aturi

export Syntax, Crypto, DagCbor, API, PLC, Identity, Lexicon, Repo, Client, RichText, OAuth, Jetstream,
       ATProtoError, SyntaxError, IdentityError, XRPCError, AuthError,
       ATProtoCryptoError, InvalidMultibaseError, InvalidCidError,
       InvalidMultikeyError, UnsupportedKeyTypeError,
       ATProtoDidError, DidNotFoundError, PoorlyFormattedDidError,
       PoorlyFormattedDidDocumentError, UnsupportedDidMethodError, UnsupportedDidWebPathError,
       LexiconValidationError, InvalidLexiconError, LexiconDefNotFoundError,
       ATProtoRepoError, MissingBlockError,
       Handle, DID, NSID, RecordKey, TID, ATDateTime, AtUri,
       @handle_str, @did_str, @nsid_str, @rkey_str, @tid_str, @at_str,
       is_valid_language, parse_language, is_valid_at_identifier, ensure_valid_at_identifier,
       varint_encode, varint_decode, read_varint,
       base16_encode, base16upper_encode, base16_decode,
       base32_encode, base32upper_encode, base32_decode,
       base58btc_encode, base58btc_decode,
       base64_encode, base64pad_encode, base64url_encode, base64urlpad_encode,
       base64_decode, base64pad_decode, base64url_decode, base64urlpad_decode,
       multibase_to_bytes, bytes_to_multibase,
       sha256, sha256hex, sha256_multihash, identity_multihash,
       CID, cid_parse, cid_from_bytes, cid_bytes, cid_for_dagcbor, cid_codec_name,
       DAG_CBOR_CODEC, RAW_CODEC, DAG_PB_CODEC,
       parse_did_key, format_did_key, parse_multikey, format_multikey,
       P256_DID_PREFIX, SECP256K1_DID_PREFIX,
       compress_pubkey, decompress_pubkey,
       AbstractEcKey, P256Key, Secp256k1Key,
       generate_key, import_key, public_key_bytes, private_key_bytes,
       jwt_alg, did_key, sign_message, sign_digest,
       verify_sig, verify_sig_digest, verify_did_sig,
       random_bytes, ripemd160, recover_pubkey,
       MULTICODEC_MULTIKEY, MULTICODEC_SECP256K1_PUB,
       DagBytes, dag_cbor_encode, dag_cbor_decode,
       LexiconModel, LexiconObject, LexiconRecord,
       LexiconMessage, LexiconParams, LexiconInput, LexiconOutput,
       CIDLink, ATBytes, BlobRef, UnknownObject,
       EndpointError, QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint,
       LEXICON_TYPES, LEXICON_ENDPOINTS, LEXICON_TOKENS,
       lexicon_type, needs_type_tag, record_key_type,
       is_did_plc, ensure_did_plc, is_did_web, ensure_did_web,
       is_atproto_did, ensure_atproto_did,
       did_web_to_url, build_did_web_url,
       DidDocument, DidService, DidVerificationMethod,
       get_did, get_handle, get_signing_key,
       get_pds_endpoint, get_notif_endpoint, get_feed_gen_endpoint,
       AtprotoData, parse_to_atproto_document, ensure_atproto_data,
       DidMemoryCache, cache_did!, check_cache, clear_entry!, clear!, CacheResult,
       PlcResolver, WebResolver, DidResolver,
       resolve, resolve_document, ensure_resolve,
       resolve_atproto_data, resolve_atproto_key, verify_signature,
       PlcClient, get_document, get_last_operation, get_audit_log, get_ops,
       plc_genesis_did, verify_legacy_create, verify_operation,
       DEFAULT_PLC_URL, DEFAULT_DOH_URL,
       DIDVerificationMethod, DIDService, DIDDocument,
       parse_did_document, pds_endpoint, atproto_handle, signing_key,
       ResolvedIdentity, IdentityResolver, clear_cache!,
       did_web_url, resolve_did, resolve_handle, verify_handle, resolve_identity,
       Lexicons, add_lexicon!, load_bundled_lexicons, get_def, get_def_or_throw,
       parse_lexicon_doc, to_lex_uri, validate_lex_ref_variant,
       assert_valid_record, assert_valid_xrpc_params,
       assert_valid_xrpc_input, assert_valid_xrpc_output,
       blob_ref_from_json, blob_ref_to_json, blob_ref_from_ipld, blob_ref_to_ipld,
       AbstractBlockStore, MemoryBlockStore, BlockMap,
       put_block!, put_blocks!, get_block, has_block, read_obj,
       Leaf, MST, leading_zeros_on_hash, is_valid_mst_key, ensure_valid_mst_key,
       mst_pointer, mst_create, mst_load, mst_add, mst_get, mst_update, mst_delete,
       mst_leaves, mst_list, mst_leaf_count, mst_get_layer!, mst_all_cids,
       mst_get_unstored_blocks, mst_cids_for_path, mst_equals,
       DataDiff, mst_diff,
       CarReader, read_car, write_car, write_car_v2, car_blocks,
       create_commit, load_commit, verify_commit_sig, verify_commit_chain,
       DEFAULT_SERVICE, PUBLIC_APPVIEW, DEFAULT_CHAT_PROXY,
       Session, RateLimitInfo, AtpAgent,
       service_url, session, is_authenticated, rate_limit,
       with_proxy, with_labelers, chat_agent,
       save_session, load_session,
       login!, refresh_session!, resume_session!, logout!,
       xrpc, xrpc_query, xrpc_procedure,
       XRPCPages, XRPCItems, eachpage, eachitem,
       get_profile, get_timeline, get_author_feed, get_post_thread,
       get_record, list_records, create_record, put_record, delete_record,
       upload_blob, post!,
       like!, unlike!, repost!, unrepost!,
       follow!, unfollow!, mute!, unmute!, block!, unblock!,
       reply_ref, reply!, quote_embed, quote_with_media_embed, quote_post!,
       external_embed, image_embed,
       get_notifications, get_unread_count, update_seen_notifications!,
       get_preferences, get_saved_feeds,
       get_bookmarks, create_bookmark!, delete_bookmark!,
       list_convos, get_convo_messages, send_chat_message!, update_convo_read!,
       RichTextDoc, RichTextSegment, RichTextBuilder,
       add_text!, add_link!, add_mention!, add_tag!, build,
       grapheme_length, byte_length, byte_slice,
       detect_mentions, detect_links, detect_tags, detect_facets, richtext,
       segments, is_mention, is_link, is_tag, mention_did, link_uri, tag_value,
       OAuthClientMetadata, OAuthSession,
       ServiceAuthError, ServiceAuthClaims,
       validate_client_metadata, generate_pkce, generate_dpop_key,
       build_dpop_proof,
       discover_authorization_server, pushed_authorization_request,
       build_par_authorization_url, build_authorization_url,
       exchange_code, refresh_token, oauth_request, oauth_transport,
       create_service_jwt, verify_service_jwt,
       sign_jwt_es256k, sign_jwt_es256, verify_jwt_es256k, verify_jwt_es256,
       jwt_decode, client_metadata_to_json, jwk_public_key, jwk_thumbprint,
       DEFAULT_JETSTREAM_URL, JETSTREAM_URLS,
       JetstreamEvent, JetstreamCommitEvent, JetstreamIdentityEvent,
       JetstreamAccountEvent, JetstreamUnknownEvent,
       JetstreamStream,
       ZstdDecompressor, zstd_compress, zstd_decompress,
       save_cursor, load_cursor,
       parse_jetstream_event, subscribe_jetstream, update_options!, last_cursor, aturi,
       lexicons_path, get_lexicons, load_lexicon

end # module ATProto
