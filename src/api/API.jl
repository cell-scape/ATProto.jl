module API

using Base64
using JSON
using StructUtils
using ..Syntax: DID, Handle, NSID, RecordKey, TID, ATDateTime, AtUri

include("types.jl")
include("generated/types.jl")
include("generated/registry.jl")
include("generated/endpoints.jl")
include("generated/namespaces.jl")

export LexiconModel, LexiconObject, LexiconRecord,
       LexiconMessage, LexiconParams, LexiconInput, LexiconOutput,
       CIDLink, ATBytes, BlobRef, UnknownObject,
       EndpointError, QueryEndpoint, ProcedureEndpoint, SubscriptionEndpoint,
       LEXICON_TYPES, LEXICON_ENDPOINTS, LEXICON_TOKENS,
       lexicon_type, needs_type_tag, record_key_type,
       App, Chat, Com, Tools

end # module API
