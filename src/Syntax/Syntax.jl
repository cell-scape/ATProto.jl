module Syntax

using Dates

export ATProtoSyntaxError,
    InvalidDidError,
    InvalidHandleError,
    InvalidAtIdentifierError,
    InvalidNsidError,
    InvalidTidError,
    InvalidRecordKeyError,
    InvalidAtUriError,
    InvalidDatetimeError,
    is_valid_did,
    ensure_valid_did,
    did_method,
    is_valid_handle,
    ensure_valid_handle,
    normalize_handle,
    normalize_and_ensure_valid_handle,
    is_valid_tld,
    INVALID_HANDLE,
    is_did_identifier,
    is_handle_identifier,
    is_valid_at_identifier,
    ensure_valid_at_identifier,
    NSID,
    is_valid_nsid,
    ensure_valid_nsid,
    parse_nsid,
    nsid_authority,
    nsid_name,
    make_nsid,
    TID,
    is_valid_tid,
    ensure_valid_tid,
    format_tid,
    parse_tid,
    tid_timestamp,
    tid_clockid,
    is_valid_record_key,
    ensure_valid_record_key,
    AtURI,
    at_uri,
    host,
    did,
    origin,
    pathname,
    query,
    fragment,
    collection,
    rkey,
    collection_safe,
    rkey_safe,
    is_valid_datetime,
    ensure_datetime_string,
    datetime_string,
    parse_datetime,
    normalize_datetime,
    is_valid_language,
    parse_language

include("errors.jl")
include("did.jl")
include("handle.jl")
include("at_identifier.jl")
include("nsid.jl")
include("tid.jl")
include("record_key.jl")
include("at_uri.jl")
include("datetime.jl")
include("language.jl")

end # module
