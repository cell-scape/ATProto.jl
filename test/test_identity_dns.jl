using Test
using Sockets
using ATProto
using ATProto.Identity

# --- hand-crafted DNS wire format helpers ----------------------------------------

"Build a DNS TXT response answering `qname` with TXT records."
function make_dns_response(id::UInt16, qname::String, txt_records::Vector{String};
                           ancount = length(txt_records))
    io = IOBuffer()
    write(io, hton(id))
    write(io, UInt8(0x81), UInt8(0x80))  # QR=1, RD=1, RA=1
    write(io, hton(UInt16(1)))           # QD
    write(io, hton(UInt16(ancount)))     # AN
    write(io, hton(UInt16(0)), hton(UInt16(0)))  # NS, AR
    # question
    for label in split(qname, ".")
        write(io, UInt8(length(label)), codeunits(label))
    end
    write(io, UInt8(0))
    write(io, hton(UInt16(16)), hton(UInt16(1)))  # TXT, IN
    # answers
    for record in txt_records
        write(io, UInt8(0xc0), UInt8(0x0c))  # name: pointer to question
        write(io, hton(UInt16(16)), hton(UInt16(1)))  # TXT, IN
        write(io, hton(UInt32(300)))        # TTL
        bytes = codeunits(record)
        # split into <=255-byte chunks
        chunks = UInt8[]
        i = 1
        while i <= length(bytes)
            n = min(255, length(bytes) - i + 1)
            push!(chunks, UInt8(n))
            append!(chunks, bytes[i:i+n-1])
            i += n
        end
        write(io, hton(UInt16(length(chunks))))
        write(io, chunks)
    end
    return take!(io)
end

@testset "DNS query build" begin
    q = build_dns_txt_query("_atproto.example.com"; id = UInt16(0x1234))
    @test length(q) > 17
    @test q[1] == 0x12 && q[2] == 0x34
    @test q[3] == 0x01 && q[4] == 0x00  # RD=1
    @test q[5:6] == [0x00, 0x01]        # QDCOUNT=1
    # question name ends with TXT/IN
    @test q[end-3] == 0x00 && q[end-2] == 0x10  # root label, TXT type
end

@testset "DNS TXT response parsing" begin
    id = UInt16(0xbeef)
    resp = make_dns_response(id, "_atproto.example.com",
                             ["did=did:plc:ewvi7nx4oun5hl7s6yqkgcto"])
    records = parse_dns_txt_response(resp; id)
    @test records == ["did=did:plc:ewvi7nx4oun5hl7s6yqkgcto"]

    # multiple records: joined per-record, chunked strings concatenated
    resp2 = make_dns_response(id, "_atproto.example.com",
                              ["other=1", "did=did:web:example.com"])
    @test parse_dns_txt_response(resp2; id) == ["other=1", "did=did:web:example.com"]

    # a long record is split into 255-byte chunks and re-joined
    long = "did=" * "x"^600
    resp3 = make_dns_response(id, "_atproto.example.com", [long])
    @test parse_dns_txt_response(resp3; id) == [long]

    # no answers
    resp4 = make_dns_response(id, "_atproto.example.com", String[])
    @test parse_dns_txt_response(resp4; id) == String[]

    # wrong transaction id
    @test_throws ArgumentError parse_dns_txt_response(resp; id = UInt16(1))
    # too short
    @test_throws ArgumentError parse_dns_txt_response(UInt8[0,0,0,0,0,0])
    # not a response (QR=0)
    notresp = vcat(resp[1:2], UInt8(0x01), resp[4:end])
    @test_throws ArgumentError parse_dns_txt_response(notresp; id)
    # truncated
    @test_throws ArgumentError parse_dns_txt_response(resp[1:length(resp)-5]; id)
end

@testset "atproto TXT record selection" begin
    # exactly one did= record wins
    recs = ["did=did:plc:ewvi7nx4oun5hl7s6yqkgcto"]
    r = ATProto.Identity._parse_atproto_records(recs)
    @test r == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"

    # zero did= records -> nothing
    @test ATProto.Identity._parse_atproto_records(["hello=world"]) === nothing
    # two did= records -> nothing (ambiguous)
    @test ATProto.Identity._parse_atproto_records(
        ["did=did:plc:a", "did=did:plc:b"]) === nothing
end

@testset "system_nameservers" begin
    servers = system_nameservers()
    @test servers isa Vector{String}
    # entries parse as IP addresses on this system (when present)
    for s in servers
        @test occursin(r"^[0-9a-fA-F.:]+$", s)
    end
end
