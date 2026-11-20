module Jetstream

using HTTP
using JSON
using StructUtils
using Zstd_jll: libzstd

using ..Syntax: SyntaxError, DID, Handle, NSID, RecordKey, AtUri
using ..API: LexiconModel, LexiconObject, UnknownObject

include("zstd.jl")
include("types.jl")
include("stream.jl")

export DEFAULT_JETSTREAM_URL, JETSTREAM_URLS,
       JetstreamEvent, JetstreamCommitEvent, JetstreamIdentityEvent,
       JetstreamAccountEvent, JetstreamUnknownEvent,
       JetstreamStream,
       ZstdDecompressor, zstd_compress, zstd_decompress,
       save_cursor, load_cursor,
       parse_jetstream_event, subscribe_jetstream, update_options!, last_cursor, aturi

end # module Jetstream
