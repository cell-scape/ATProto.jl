module Syntax

using Dates
using StructUtils

include("errors.jl")
include("ascii.jl")
include("handle.jl")
include("did.jl")
include("nsid.jl")
include("recordkey.jl")
include("datetime.jl")
include("aturi.jl")
include("language.jl")
include("at_identifier.jl")

export ATProtoError, SyntaxError,
       Handle, DID, NSID, RecordKey, TID, ATDateTime, AtUri,
       @handle_str, @did_str, @nsid_str, @rkey_str, @tid_str, @at_str,
       is_valid_handle, ensure_valid_handle, is_valid_handle_regex, ensure_valid_handle_regex,
       normalize_handle, normalize_and_ensure_valid_handle, is_valid_tld,
       valid_handle_char, valid_handle_chars, INVALID_HANDLE, DISALLOWED_TLDS,
       is_valid_did, ensure_valid_did, is_valid_did_regex, ensure_valid_did_regex,
       valid_did_char, valid_did_chars, did_method, did_identifier,
       is_valid_at_identifier, ensure_valid_at_identifier,
       is_valid_nsid, ensure_valid_nsid, is_valid_nsid_regex, ensure_valid_nsid_regex,
       valid_nsid_char, nsid, authority, name,
       is_valid_record_key, ensure_valid_record_key, valid_record_key_char,
       is_valid_tid, ensure_valid_tid, tid_timestamp_us, tid_clockid, next_tid,
       is_valid_datetime, ensure_valid_datetime,
       is_valid_language, parse_language,
       is_valid_aturi, ensure_valid_aturi, is_valid_aturi_regex, parse_aturi,
       protocol, origin, hostname, collection, rkey, fragment

end # module Syntax
