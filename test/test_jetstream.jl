using Test
using ATProto
using ATProto.Jetstream
using ATProto.DagCbor
using ATProto.Crypto
using JSON

# --- test helpers: build firehose frames (DAG-CBOR header + payload) --------------

function make_firehose_frame(header::Dict, payload::Vector{UInt8} = UInt8[])
    return vcat(dag_cbor_encode(header), payload)
end

@testset "firehose frame parsing: #commit" begin
    # create op with a CID
    cid_str = string(cid_for_dagcbor("test record"))
    commit_body = Dict{String,Any}(
        "seq" => 12345,
        "rev" => "3jzfcijpj2z2a",
        "did" => "did:plc:ewvi7nx4oun5hl7s6yqkgcto",
        "prev" => nothing,
        "ops" => [Dict{String,Any}(
            "action" => "create",
            "path" => "com.example.post/3jzfcijpj2z2a",
            "cid" => cid_parse(cid_str),
        )],
    )
    frame = make_firehose_frame(
        Dict{String,Any}("op" => 1, "t" => "#commit"),
        dag_cbor_encode(commit_body))
    ev = parse_firehose_frame(frame)
    @test ev isa CommitEvent
    @test ev.seq == 12345
    @test ev.did == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
    @test ev.operation == :create
    @test ev.collection == "com.example.post"
    @test ev.rkey == "3jzfcijpj2z2a"
    @test ev.cid !== nothing && string(ev.cid) == cid_str

    # delete op (no record)
    delete_body = Dict{String,Any}(
        "seq" => 12346,
        "rev" => "3jzfcijpj2z2b",
        "did" => "did:plc:ewvi7nx4oun5hl7s6yqkgcto",
        "ops" => [Dict{String,Any}(
            "action" => "delete",
            "collection" => "com.example.post",
            "rkey" => "3jzfcijpj2z2a",
        )],
    )
    frame2 = make_firehose_frame(
        Dict{String,Any}("op" => 1, "t" => "#commit"),
        dag_cbor_encode(delete_body))
    ev2 = parse_firehose_frame(frame2)
    @test ev2 isa CommitEvent
    @test ev2.operation == :delete
    @test ev2.collection == "com.example.post"
    @test ev2.rkey == "3jzfcijpj2z2a"
    @test ev2.record === nothing
    @test ev2.cid === nothing
end

@testset "firehose frame parsing: #identity" begin
    body = Dict{String,Any}(
        "seq" => 999,
        "did" => "did:plc:ewvi7nx4oun5hl7s6yqkgcto",
        "handle" => "newhandle.example.com",
        "time" => "2023-06-01T12:00:00.000Z",
    )
    frame = make_firehose_frame(
        Dict{String,Any}("op" => 1, "t" => "#identity"),
        dag_cbor_encode(body))
    ev = parse_firehose_frame(frame)
    @test ev isa IdentityEvent
    @test ev.did == "did:plc:ewvi7nx4oun5hl7s6yqkgcto"
    @test ev.handle == "newhandle.example.com"
    @test ev.seq == 999
end

@testset "firehose frame parsing: #account" begin
    body = Dict{String,Any}(
        "seq" => 1000,
        "did" => "did:plc:ewvi7nx4oun5hl7s6yqkgcto",
        "active" => false,
        "status" => "suspended",
        "time" => "2023-06-01T12:00:00.000Z",
    )
    frame = make_firehose_frame(
        Dict{String,Any}("op" => 1, "t" => "#account"),
        dag_cbor_encode(body))
    ev = parse_firehose_frame(frame)
    @test ev isa AccountEvent
    @test ev.active == false
    @test ev.status == "suspended"
    @test ev.seq == 1000
end

@testset "firehose frame parsing: #info" begin
    frame = make_firehose_frame(Dict{String,Any}("op" => 2, "status" => "Available"))
    result = parse_firehose_frame(frame)
    @test result isa NamedTuple
    @test result.op == 2
    @test result.status == "Available"
end

@testset "firehose frame parsing: unknown" begin
    # unknown message type
    frame = make_firehose_frame(Dict{String,Any}("op" => 1, "t" => "#unknown"))
    @test parse_firehose_frame(frame) === nothing

    # op=3 (invalid)
    frame2 = make_firehose_frame(Dict{String,Any}("op" => 3))
    @test parse_firehose_frame(frame2) === nothing
end

@testset "jetstream JSON conversion" begin
    ev = CommitEvent(42, "3jzfcijpj2z2a", "did:plc:abc", :create,
                     "app.bsky.feed.post", "3jzfcijpj2z2a",
                     Dict{String,Any}("text" => "hello"), nothing, nothing, nothing)
    js = firehose_to_jetstream_json(ev)
    @test js["kind"] == "commit"
    @test js["cursor"] == 42
    @test js["did"] == "did:plc:abc"
    @test js["commit"]["operation"] == "create"
    @test js["commit"]["collection"] == "app.bsky.feed.post"
    @test js["commit"]["rkey"] == "3jzfcijpj2z2a"
    @test js["commit"]["record"]["text"] == "hello"

    id = IdentityEvent(43, "did:plc:abc", "new.example.com", "2023-06-01T12:00:00Z")
    js_id = firehose_to_jetstream_json(id)
    @test js_id["kind"] == "identity"
    @test js_id["identity"]["handle"] == "new.example.com"

    acct = AccountEvent(44, "did:plc:abc", false, "takendown", "2023-06-01T12:00:00Z")
    js_acct = firehose_to_jetstream_json(acct)
    @test js_acct["kind"] == "account"
    @test js_acct["account"]["active"] == false
    @test js_acct["account"]["status"] == "takendown"
end

@testset "URL parameter replacement" begin
    using ATProto.Jetstream: _replace_param
    @test _replace_param("https://example.com/ws", "cursor", "123") ==
          "https://example.com/ws?cursor=123"
    @test _replace_param("https://example.com/ws?cursor=100&foo=bar", "cursor", "200") ==
          "https://example.com/ws?foo=bar&cursor=200"
    @test _replace_param("https://example.com/ws?foo=bar", "cursor", "5") ==
          "https://example.com/ws?foo=bar&cursor=5"
end
