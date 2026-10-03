# Minimal DNS TXT-record client. Julia's Sockets stdlib does not expose DNS
# record lookups, so this implements just enough of RFC 1035 to query TXT
# records over UDP: build a query, send it to a nameserver, parse the
# character-string chunks out of the answers.

const DNS_TXT_TYPE = UInt16(16)
const DNS_CLASS_IN = UInt16(1)

"""
    build_dns_txt_query(name; id=rand(UInt16)) -> Vector{UInt8}

Wire-format DNS query for the TXT records of `name` (recursion desired).
"""
function build_dns_txt_query(name::AbstractString; id::UInt16 = rand(UInt16))::Vector{UInt8}
    return _build(name, id)
end

function _build(name::AbstractString, id::UInt16)
    io = IOBuffer()
    write(io, hton(id))
    write(io, UInt8(0x01), UInt8(0x00))                      # RD=1
    write(io, hton(UInt16(1)))                               # QDCOUNT
    write(io, hton(UInt16(0)), hton(UInt16(0)), hton(UInt16(0)))  # AN NS AR
    for label in split(name, ".")
        isempty(label) && continue
        length(label) <= 63 || throw(ArgumentError("DNS label too long"))
        write(io, UInt8(ncodeunits(label)), codeunits(label))
    end
    write(io, UInt8(0))
    write(io, hton(DNS_TXT_TYPE), hton(DNS_CLASS_IN))
    return take!(io)
end

"""
    parse_dns_txt_response(bytes; id=nothing) -> Vector{String}

Parse a DNS response into the joined character-strings of its TXT answer
records (chunks within a record are concatenated, per RFC 1035). Non-TXT
records are skipped. Throws `ArgumentError` on malformed messages; when `id`
is given, a mismatched transaction id is an error.
"""
function parse_dns_txt_response(bytes::AbstractVector{UInt8};
                                id::Union{UInt16,Nothing} = nothing)::Vector{String}
    length(bytes) >= 12 || throw(ArgumentError("DNS response too short"))
    msg_id = UInt16((UInt16(bytes[1]) << 8) | bytes[2])
    id === nothing || msg_id == id || throw(ArgumentError("DNS transaction id mismatch"))
    qr = bytes[3] >> 7
    qr == 1 || throw(ArgumentError("not a DNS response"))
    rcode = bytes[4] & 0x0f
    rcode == 0 || throw(ArgumentError("DNS error response (rcode $rcode)"))
    qdcount = _u16(bytes, 5)
    ancount = _u16(bytes, 7)

    pos = 13
    for _ in 1:qdcount
        pos = _skip_name(bytes, pos)
        pos += 4  # QTYPE + QCLASS
    end

    records = String[]
    for _ in 1:ancount
        pos = _skip_name(bytes, pos)
        pos + 10 > length(bytes) + 1 && throw(ArgumentError("truncated DNS answer"))
        rtype = _u16(bytes, pos)
        rdlength = _u16(bytes, pos + 8)
        pos += 10
        pos + rdlength - 1 > length(bytes) && throw(ArgumentError("truncated DNS RDATA"))
        if rtype == DNS_TXT_TYPE
            endpos = pos + rdlength
            chunks = UInt8[]
            p = pos
            while p < endpos
                p + 1 > length(bytes) + 1 && throw(ArgumentError("truncated TXT chunk"))
                clen = Int(bytes[p])
                p += 1
                p + clen - 1 > length(bytes) && throw(ArgumentError("truncated TXT chunk"))
                append!(chunks, bytes[p:p+clen-1])
                p += clen
            end
            push!(records, String(copy(chunks)))
            pos = endpos
        else
            pos += rdlength
        end
    end
    return records
end

@inline _u16(bytes, i) = UInt16((UInt16(bytes[i]) << 8) | bytes[i+1])

"Skip a (possibly compressed) domain name; returns the next section position."
function _skip_name(bytes::AbstractVector{UInt8}, pos::Int)::Int
    while true
        pos > length(bytes) && throw(ArgumentError("truncated DNS name"))
        len = Int(bytes[pos])
        if len == 0
            return pos + 1
        elseif len & 0xc0 == 0xc0  # compression pointer
            pos + 2 <= length(bytes) + 1 || throw(ArgumentError("truncated DNS pointer"))
            return pos + 2
        elseif len & 0xc0 != 0
            throw(ArgumentError("unsupported DNS label type"))
        else
            pos += 1 + len
        end
    end
end

"""
    system_nameservers() -> Vector{String}

Nameserver IPs from `/etc/resolv.conf` (or an empty vector).
"""
function system_nameservers()::Vector{String}
    servers = String[]
    path = "/etc/resolv.conf"
    isfile(path) || return servers
    for line in eachline(path)
        m = match(r"^\s*nameserver\s+(\S+)", line)
        m !== nothing && push!(servers, m[1])
    end
    return servers
end

"Query one nameserver over UDP with a timeout; `nothing` on failure."
function _query_nameserver(server::AbstractString, query::AbstractVector{UInt8},
                            timeout::Real)::Union{Vector{UInt8},Nothing}
    ip = try
        parse(IPAddr, server)
    catch
        try
            getaddrinfo(server)
        catch
            return nothing
        end
    end
    sock = UDPSocket()
    local result = nothing
    local done = false
    task = @async begin
        try
            result = recv(sock)
        catch
            result = nothing
        end
        done = true
    end
    send(sock, ip, 53, query)
    timer = Timer(timeout) do _
        done || close(sock)
    end
    try
        t0 = time()
        while !done && time() - t0 < timeout + 0.5
            sleep(0.01)
        end
    finally
        close(timer)
        close(sock)
    end
    wait(task)
    return result
end

"""
    resolve_handle_dns(handle; nameservers=system_nameservers(), timeout=2.0,
                       id=rand(UInt16)) -> Union{String, Nothing}

Resolve a handle to a DID via the `_atproto.<handle>` DNS TXT record
(atproto.com/specs/handle). Returns `nothing` when no single valid record
exists.
"""
function resolve_handle_dns(handle::AbstractString;
                            nameservers::Vector{String} = system_nameservers(),
                            timeout::Real = 2.0,
                            id::UInt16 = rand(UInt16))::Union{String,Nothing}
    isempty(nameservers) && return nothing
    query_name::String = string("_atproto.", handle)
    query = _build(query_name, id)
    for server in nameservers
        response = _query_nameserver(server, query, timeout)
        response === nothing && continue
        records = try
            parse_dns_txt_response(response; id)
        catch
            continue
        end
        did = _parse_atproto_records(records)
        did !== nothing && return did
    end
    return nothing
end

"Exactly one TXT record may start with `did=`; its value is the DID."
function _parse_atproto_records(records::Vector{String})::Union{String,Nothing}
    found = String[r for r in records if startswith(r, "did=")]
    length(found) == 1 || return nothing
    return found[1][length("did=")+1:end]
end
