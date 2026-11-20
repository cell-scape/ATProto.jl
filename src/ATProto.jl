module ATProto

using Base64
using Dates
using HTTP
using JSON
using StructUtils
using Unicode

include("syntax/Syntax.jl")
include("api/API.jl")
include("identity/Identity.jl")
include("client/Client.jl")
include("richtext/RichText.jl")
include("jetstream/Jetstream.jl")
include("lexicons.jl")

using .Syntax: ATProtoError, SyntaxError,
               Handle, DID, NSID, RecordKey, TID, ATDateTime, AtUri,
               @handle_str, @did_str, @nsid_str, @rkey_str, @tid_str, @at_str

using .API: LexiconModel, LexiconObject, LexiconRecord,
            LexiconMessage, LexiconParams, LexiconInput, LexiconOutput,
            CIDLink, ATBytes, BlobRef, UnknownObject,
            EndpointError, QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint,
            LEXICON_TYPES, LEXICON_ENDPOINTS, LEXICON_TOKENS,
            lexicon_type, needs_type_tag, record_key_type

using .Identity: DEFAULT_PLC_URL, DEFAULT_DOH_URL,
                 IdentityError,
                 DIDVerificationMethod, DIDService, DIDDocument,
                 parse_did_document, pds_endpoint, atproto_handle, signing_key,
                 ResolvedIdentity, IdentityResolver, clear_cache!,
                 did_web_url, resolve_did, resolve_handle, verify_handle, resolve_identity

using .Client: DEFAULT_SERVICE, PUBLIC_APPVIEW,
               XRPCError, AuthError,
               Session, RateLimitInfo, AtpAgent,
               service_url, session, is_authenticated, rate_limit,
               with_proxy, with_labelers,
               login!, refresh_session!, resume_session!, logout!,
               xrpc, xrpc_query, xrpc_procedure,
               XRPCPages, XRPCItems, eachpage, eachitem,
               get_profile, get_timeline, get_author_feed, get_post_thread,
               get_record, list_records, create_record, put_record, delete_record,
               upload_blob, post!

using .RichText: RichTextDoc, RichTextSegment, RichTextBuilder,
                 add_text!, add_link!, add_mention!, add_tag!, build,
                 grapheme_length, byte_length, byte_slice,
                 detect_mentions, detect_links, detect_tags, detect_facets, richtext,
                 segments, is_mention, is_link, is_tag, mention_did, link_uri, tag_value

# Convenience overload: publish a RichTextDoc directly via `post!(agent, rt; ...)`
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

using .Jetstream: DEFAULT_JETSTREAM_URL, JETSTREAM_URLS,
                  JetstreamEvent, JetstreamCommitEvent, JetstreamIdentityEvent,
                  JetstreamAccountEvent, JetstreamUnknownEvent,
                  JetstreamStream,
                  parse_jetstream_event, subscribe_jetstream, update_options!, last_cursor, aturi

export Syntax, API, Identity, Client, RichText, Jetstream,
       ATProtoError, SyntaxError, IdentityError, XRPCError, AuthError,
       Handle, DID, NSID, RecordKey, TID, ATDateTime, AtUri,
       @handle_str, @did_str, @nsid_str, @rkey_str, @tid_str, @at_str,
       LexiconModel, LexiconObject, LexiconRecord,
       LexiconMessage, LexiconParams, LexiconInput, LexiconOutput,
       CIDLink, ATBytes, BlobRef, UnknownObject,
       EndpointError, QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint,
       LEXICON_TYPES, LEXICON_ENDPOINTS, LEXICON_TOKENS,
       lexicon_type, needs_type_tag, record_key_type,
       DEFAULT_PLC_URL, DEFAULT_DOH_URL,
       DIDVerificationMethod, DIDService, DIDDocument,
       parse_did_document, pds_endpoint, atproto_handle, signing_key,
       ResolvedIdentity, IdentityResolver, clear_cache!,
       did_web_url, resolve_did, resolve_handle, verify_handle, resolve_identity,
       DEFAULT_SERVICE, PUBLIC_APPVIEW,
       Session, RateLimitInfo, AtpAgent,
       service_url, session, is_authenticated, rate_limit,
       with_proxy, with_labelers,
       login!, refresh_session!, resume_session!, logout!,
       xrpc, xrpc_query, xrpc_procedure,
       XRPCPages, XRPCItems, eachpage, eachitem,
       get_profile, get_timeline, get_author_feed, get_post_thread,
       get_record, list_records, create_record, put_record, delete_record,
       upload_blob, post!,
       RichTextDoc, RichTextSegment, RichTextBuilder,
       add_text!, add_link!, add_mention!, add_tag!, build,
       grapheme_length, byte_length, byte_slice,
       detect_mentions, detect_links, detect_tags, detect_facets, richtext,
       segments, is_mention, is_link, is_tag, mention_did, link_uri, tag_value,
       DEFAULT_JETSTREAM_URL, JETSTREAM_URLS,
       JetstreamEvent, JetstreamCommitEvent, JetstreamIdentityEvent,
       JetstreamAccountEvent, JetstreamUnknownEvent,
       JetstreamStream,
       parse_jetstream_event, subscribe_jetstream, update_options!, last_cursor, aturi,
       lexicons_path, get_lexicons, load_lexicon

end # module ATProto
