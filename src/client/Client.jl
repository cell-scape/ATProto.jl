module Client

using Dates
using HTTP
using JSON
using StructUtils

using ..Syntax: ATProtoError, Handle, DID, NSID, RecordKey, TID, ATDateTime, AtUri
using ..API
using ..API: LexiconObject, LexiconRecord, LexiconParams,
             UnknownObject, QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint,
             LEXICON_ENDPOINTS, lexicon_type,
             ComAtprotoServerCreateSessionInput, ComAtprotoServerCreateSessionOutput,
             ComAtprotoServerRefreshSessionOutput, ComAtprotoServerGetSessionOutput

include("errors.jl")
include("session.jl")
include("agent.jl")
include("xrpc.jl")
include("pagination.jl")
include("helpers.jl")

export DEFAULT_SERVICE, PUBLIC_APPVIEW, DEFAULT_CHAT_PROXY,
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

end # module Client
