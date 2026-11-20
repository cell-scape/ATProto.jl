using ATProto
using ATProto.API
using ATProto.Jetstream
using ATProto.Syntax
using HTTP
using JSON
using Test

const Sockets = HTTP.Sockets

@testset "Jetstream WebSocket Streaming" begin
    @testset "URL builder" begin
        u0 = Jetstream._build_jetstream_url(DEFAULT_JETSTREAM_URL)
        @test u0 == DEFAULT_JETSTREAM_URL

        u1 = Jetstream._build_jetstream_url(
            DEFAULT_JETSTREAM_URL;
            wanted_collections = [nsid"app.bsky.feed.post", "app.bsky.feed.like"],
            wanted_dids = [did"did:plc:z72i7hdynmk6r22z27h6tvur"],
            cursor = 1725911162329308,
            max_message_size_bytes = 65536,
            require_hello = true,
        )
        @test occursin("wantedCollections=app.bsky.feed.post", u1)
        @test occursin("wantedCollections=app.bsky.feed.like", u1)
        @test occursin("wantedDids=did%3Aplc%3Az72i7hdynmk6r22z27h6tvur", u1)
        @test occursin("cursor=1725911162329308", u1)
        @test occursin("maxMessageSizeBytes=65536", u1)
        @test occursin("requireHello=true", u1)
    end

    @testset "Event parsing (commit, identity, account, unknown & malformed fallback)" begin
        # 1. Commit create (typed AppBskyFeedPost)
        commit_json = """{
            "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us": 1725911162329308,
            "kind": "commit",
            "commit": {
                "rev": "3l3qo2vutsw2b",
                "operation": "create",
                "collection": "app.bsky.feed.post",
                "rkey": "3l3qo2vuowo2b",
                "record": {
                    "\$type": "app.bsky.feed.post",
                    "createdAt": "2024-09-09T19:46:02.102Z",
                    "text": "hello jetstream!"
                },
                "cid": "bafyreid123"
            }
        }"""
        ev = parse_jetstream_event(commit_json)
        @test ev isa JetstreamCommitEvent
        @test ev.did == did"did:plc:z72i7hdynmk6r22z27h6tvur"
        @test ev.time_us == 1725911162329308
        @test ev.operation === :create
        @test ev.collection == nsid"app.bsky.feed.post"
        @test ev.rkey == rkey"3l3qo2vuowo2b"
        @test ev.cid == "bafyreid123"
        @test ev.record isa API.AppBskyFeedPost
        @test ev.record.text == "hello jetstream!"
        @test aturi(ev) == at"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l3qo2vuowo2b"

        # Also works from Vector{UInt8}
        @test parse_jetstream_event(Vector{UInt8}(codeunits(commit_json))) == ev

        # 2. Commit delete (no record or cid)
        del_json = """{
            "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us": 1725911162329400,
            "kind": "commit",
            "commit": {
                "rev": "3l3qo2vutsw2c",
                "operation": "delete",
                "collection": "app.bsky.feed.like",
                "rkey": "3l3qo2vuowo2c"
            }
        }"""
        del_ev = parse_jetstream_event(del_json)
        @test del_ev isa JetstreamCommitEvent
        @test del_ev.operation === :delete
        @test del_ev.record === nothing
        @test del_ev.cid === nothing

        # 3. Identity event
        id_json = """{
            "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us": 1725911162329500,
            "kind": "identity",
            "identity": {
                "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
                "handle": "Bsky.App",
                "seq": 1409752997,
                "time": "2024-09-09T19:46:02.102Z"
            }
        }"""
        id_ev = parse_jetstream_event(id_json)
        @test id_ev isa JetstreamIdentityEvent
        @test id_ev.handle == handle"bsky.app"
        @test id_ev.seq == 1409752997

        # 4. Account event
        acc_json = """{
            "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us": 1725911162329600,
            "kind": "account",
            "account": {
                "active": false,
                "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
                "seq": 1409753013,
                "time": "2024-09-09T19:46:02.102Z",
                "status": "deactivated"
            }
        }"""
        acc_ev = parse_jetstream_event(acc_json)
        @test acc_ev isa JetstreamAccountEvent
        @test acc_ev.active == false
        @test acc_ev.status == "deactivated"

        # 5. Unknown future event kind
        unk_json = """{"did": "did:plc:z72i7hdynmk6r22z27h6tvur", "time_us": 123, "kind": "future_kind", "payload": 42}"""
        unk_ev = parse_jetstream_event(unk_json)
        @test unk_ev isa JetstreamUnknownEvent
        @test unk_ev.kind == "future_kind"
        @test unk_ev.raw["payload"] == 42

        # 6. Malformed record falls back to UnknownObject when strict=false, throws when strict=true
        bad_rec_json = """{
            "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us": 1725911162329999,
            "kind": "commit",
            "commit": {
                "rev": "3l3qo2vutsw2d",
                "operation": "create",
                "collection": "app.bsky.feed.like",
                "rkey": "3l3qo2vuowo2d",
                "record": {
                    "\$type": "app.bsky.feed.like",
                    "subject": {"uri": "not-a-valid-aturi", "cid": "bafy123"},
                    "createdAt": "2024-09-09T19:46:02.102Z"
                }
            }
        }"""
        loose_ev = parse_jetstream_event(bad_rec_json; strict = false)
        @test loose_ev isa JetstreamCommitEvent
        @test loose_ev.record isa UnknownObject
        @test lexicon_type(loose_ev.record) == "app.bsky.feed.like"
        @test_throws SyntaxError parse_jetstream_event(bad_rec_json; strict = true)
    end

    @testset "Loopback WebSocket streaming, options_update & reconnect with cursor resume" begin
        targets = String[]
        client_frames = String[]
        conn_count = Ref(0)

        ev1 = JSON.json(Dict(
            "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us" => 10_000_000,
            "kind" => "commit",
            "commit" => Dict(
                "rev" => "3l3qo2vutsw2b",
                "operation" => "create",
                "collection" => "app.bsky.feed.post",
                "rkey" => "3l3qo2vuowo2b",
                "cid" => "bafy1",
                "record" => Dict("\$type" => "app.bsky.feed.post", "text" => "msg 1", "createdAt" => "2026-11-19T22:00:00Z"),
            ),
        ))
        ev2 = JSON.json(Dict(
            "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
            "time_us" => 20_000_000,
            "kind" => "identity",
            "identity" => Dict(
                "did" => "did:plc:z72i7hdynmk6r22z27h6tvur",
                "handle" => "bsky.app",
                "seq" => 2,
                "time" => "2026-11-19T22:00:01Z",
            ),
        ))

        server = HTTP.WebSockets.listen!(Sockets.localhost, 0) do ws
            conn_count[] += 1
            n = conn_count[]
            push!(targets, ws.request.target)
            if n == 1
                # Send event 1, read an options_update from client, then drop connection to trigger reconnect!
                HTTP.WebSockets.send(ws, ev1)
                msg = HTTP.WebSockets.receive(ws)
                push!(client_frames, String(msg))
                close(ws)
            else
                HTTP.WebSockets.send(ws, ev2)
                # Keep open briefly until client closes
                try
                    for _ in ws
                    end
                catch
                end
            end
        end

        try
            _, port = Sockets.getsockname(server.listener.server)
            ws_url = "ws://127.0.0.1:$port/subscribe"

            received = JetstreamEvent[]
            subscribe_jetstream(
                url = ws_url,
                wanted_collections = ["app.bsky.feed.post"],
                reconnect = true,
                reconnect_delay = 0.05,
                cursor_rewind_us = 2_000_000,
            ) do stream
                first_ev = take!(stream)
                push!(received, first_ev)
                @test last_cursor(stream) == 10_000_000

                # Send live options_update over active WebSocket
                update_options!(stream; wanted_collections = ["app.bsky.feed.post", "app.bsky.feed.like"])

                # Server drops conn 1 -> stream automatically reconnects with cursor = 10_000_000 - 2_000_000 = 8_000_000!
                second_ev = take!(stream)
                push!(received, second_ev)
                @test last_cursor(stream) == 20_000_000
                @test occursin("JetstreamStream", sprint(show, stream))
            end

            @test length(received) == 2
            @test received[1] isa JetstreamCommitEvent
            @test received[1].record.text == "msg 1"
            @test received[2] isa JetstreamIdentityEvent
            @test received[2].handle == handle"bsky.app"

            @test length(targets) == 2
            @test occursin("wantedCollections=app.bsky.feed.post", targets[1])
            @test occursin("cursor=8000000", targets[2])

            @test length(client_frames) == 1
            upd = JSON.parse(client_frames[1], Dict{String, Any})
            @test upd["type"] == "options_update"
            @test upd["payload"]["wantedCollections"] == ["app.bsky.feed.post", "app.bsky.feed.like"]
        finally
            close(server)
        end
    end
end
