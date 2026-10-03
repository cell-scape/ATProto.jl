module Identity

using ..DID
using ..Crypto
using Sockets
using HTTP

export HandleNotFoundError,
    IdentityMismatchError,
    HandleResolver,
    resolve_handle,
    ensure_handle,
    resolve_handle_dns,
    resolve_handle_http,
    parse_dns_txt_response,
    build_dns_txt_query,
    system_nameservers,
    IdResolver,
    resolve_identity,
    ensure_identity

include("errors.jl")
include("dns.jl")
include("handle.jl")
include("id_resolver.jl")

end # module
