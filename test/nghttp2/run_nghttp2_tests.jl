# End-to-end tests for the optional nghttp2 backend.
#
# Deliberately NOT part of `test/runtests.jl`. Nghttp2Wrapper.jl requires Julia
# 1.12, and gRPCServer's test environment is declared once in `[extras]` for the
# whole CI matrix — adding Nghttp2Wrapper there would make dependency resolution
# fail on the 1.10 LTS job, and not merely skip these tests.
#
# So this file lives in its own environment, built by the `nghttp2` CI job on
# the latest stable Julia only. Run it locally with:
#
#     julia --project=@nghttp2 -e '
#         using Pkg
#         Pkg.develop(path = ".")
#         Pkg.add(["Nghttp2Wrapper", "gRPCClient", "ProtoBuf", "Test"])'
#     JULIA_LOAD_PATH=@:@stdlib julia --project=@nghttp2 \
#         test/nghttp2/run_nghttp2_tests.jl
#
# That JULIA_LOAD_PATH is not optional if you want to reproduce CI: without it
# your default environment quietly supplies anything missing here, and the run
# passes locally while failing on a bare runner. Keep `@stdlib` — dropping it
# hides Sockets and Test.
#
# The suite in `test/backends/test_httpjl_backend.jl` covers the *opposite*
# case — the extension absent — and runs on every job.

using Test
using gRPCServer
using Nghttp2Wrapper
using gRPCClient

const GRPCCLIENT_DIR = joinpath(@__DIR__, "..", "integration", "grpcclient")

include(joinpath(GRPCCLIENT_DIR, "generated", "interop", "interop.jl"))
using .interop
include(joinpath(GRPCCLIENT_DIR, "client_stubs.jl"))
include(joinpath(GRPCCLIENT_DIR, "remote_harness.jl"))

@testset "Nghttp2Backend end to end" begin
    @testset "the extension is loaded" begin
        # First, and not a formality. If the extension were missing, every
        # assertion below would fail for reasons unrelated to nghttp2 — and a
        # job that silently exercises nothing is worse than no job, because it
        # reports green.
        @test Base.get_extension(gRPCServer, :gRPCServerNghttp2Ext) !== nothing
        @test Nghttp2Backend() isa gRPCServer.AbstractHTTP2Backend
        @test gRPCServer.uses_serve_grpc(Nghttp2Backend())
    end

    @testset "construction raises for unsupported features" begin
        # enable_reflection is a bidi-only service, refused on Nghttp2.
        @test_throws UnsupportedFeatureError GRPCServerNghttp2(
            "127.0.0.1", 50210; enable_reflection=true)
        # mTLS is silently ignored by the extension (cert/key only). TLSConfig
        # stores paths without reading them, so fake paths are fine here.
        @test_throws UnsupportedFeatureError GRPCServerNghttp2(
            "127.0.0.1", 50211;
            tls=TLSConfig(cert_chain="/fake/server.crt", private_key="/fake/server.key",
                          client_ca="/fake/ca.crt", require_client_cert=true))
        # HTTP.jl listener timeouts are not applicable to this backend.
        @test_throws UnsupportedFeatureError GRPCServerNghttp2(
            "127.0.0.1", 50212; read_timeout=5.0)
        # The receive cap IS enforced now (read_message! refuses an over-cap
        # length prefix), so this keyword is honoured rather than rejected.
        @test GRPCServerNghttp2(
            "127.0.0.1", 50213; max_receive_message_length=8 * 1024 * 1024) isa GRPCServer
        # Default-config construction works; basic TLS (cert/key) works;
        # enable_health_check is allowed (Check works; Watch refused per-request).
        @test GRPCServerNghttp2("127.0.0.1", 50214) isa GRPCServer
        @test GRPCServerNghttp2(
            "127.0.0.1", 50215;
            tls=TLSConfig(cert_chain="/fake/server.crt", private_key="/fake/server.key")) isa GRPCServer
        @test GRPCServerNghttp2("127.0.0.1", 50216; enable_health_check=true) isa GRPCServer
    end

    grpc_init()
    try
        with_remote_server(backend = "nghttp2") do ts
            # The server reports the backend it actually constructed, so this is
            # an assertion about the running process, not about our intent.
            @test ts.backend == "nghttp2"

            @testset "unary round-trip" begin
                client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                r = grpc_sync_request(client, InteropRequest(Int32(7), "hello nghttp2"))
                @test r.id == Int32(7)
                @test r.result == "hello nghttp2"
            end

            @testset "unary error status propagates through trailers" begin
                # The whole reason this backend needs Nghttp2Wrapper >= 0.2.1: a
                # gRPC status travels in the trailing HEADERS block, so without
                # trailer support no call could report anything but success.
                client = InteropTestService_Fail_Client("127.0.0.1", ts.port)
                ex = try
                    grpc_sync_request(client, InteropRequest(Int32(5), "not found"))
                    nothing
                catch e
                    e
                end
                @test ex isa gRPCClient.gRPCServiceCallException
                @test ex.grpc_status == 5   # NOT_FOUND
                @test occursin("not found", ex.message)
            end

            @testset "server streaming is refused, not mistimed" begin
                # Nghttp2Wrapper's handler is buffered, so responses cannot be
                # emitted message by message. The backend refuses rather than
                # serving with the wrong timing — a bidirectional exchange would
                # otherwise deadlock waiting for a reply flushed only at the end.
                client = InteropTestService_StreamResponses_Client("127.0.0.1", ts.port)
                response_c = Channel{InteropResponse}(16)
                ex = try
                    req = grpc_async_request(client, InteropRequest(Int32(5), "msg"),
                                             response_c)
                    for _ in response_c
                    end
                    grpc_async_await(req)
                    nothing
                catch e
                    e
                end
                @test ex isa gRPCClient.gRPCServiceCallException
                @test ex.grpc_status == 12   # UNIMPLEMENTED
                @test occursin("HTTPjlBackend", ex.message)   # names the way out
            end
        end
    finally
        grpc_shutdown()
    end
end

@testset "stop_serving! forwards force and timeout" begin
    # Driven with a raw nghttp2 client session over h2c rather than gRPCClient:
    # the point here is the adapter's shutdown method, and an in-process
    # gRPCClient call against a colocated server is unreliable for reasons
    # unrelated to it (see remote_harness.jl).
    using Sockets
    using Nghttp2Wrapper: HTTP2Server, ServerResponse, Callbacks, NVPair,
                          to_nghttp2_nv, nghttp2_session_client_new,
                          nghttp2_session_del, nghttp2_submit_settings,
                          nghttp2_submit_request2, Nghttp2SettingsEntry,
                          NGHTTP2_FLAG_NONE, listener_port

    function connect_retry(port)
        for _ in 1:50
            try
                return Sockets.connect("127.0.0.1", port)
            catch
                sleep(0.2)
            end
        end
        return nothing
    end

    function fire_request(sock, path)
        cb = Callbacks()
        rv, session = nghttp2_session_client_new(cb.ptr)
        rv == 0 || error("client session")
        nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE,
                                Ptr{Nghttp2SettingsEntry}(C_NULL), 0)
        hs = [NVPair(":method", "POST"), NVPair(":path", path),
              NVPair(":scheme", "http"), NVPair(":authority", "localhost")]
        nva = [to_nghttp2_nv(h) for h in hs]
        GC.@preserve hs nva begin
            nghttp2_submit_request2(session, C_NULL, pointer(nva), length(nva),
                                    C_NULL, C_NULL)
            write(sock, Nghttp2Wrapper._session_send_all(session))
            flush(sock)
        end
        return session, cb
    end

    function await_flag(flag, seconds)
        deadline = time() + seconds
        while !flag[] && time() < deadline
            sleep(0.05)
        end
        return flag[]
    end

    # `force = true` must not wait for the handler; the default must.
    for (label, kwargs, waits) in (("forced", (; force = true), false),
                                   ("graceful", (; timeout = 30.0), true))
        entered = Ref(false)
        finished = Ref(false)
        handle = HTTP2Server(0) do req
            entered[] = true
            sleep(4.0)
            finished[] = true
            ServerResponse(200, "slow")
        end
        port = listener_port(handle)
        sock = connect_retry(port)
        @test sock !== nothing
        session, cb = fire_request(sock, "/slow")
        @test await_flag(entered, 15.0)

        started = time()
        gRPCServer.stop_serving!(Nghttp2Backend(), handle; kwargs...)
        elapsed = time() - started

        if waits
            @test finished[]
            @test elapsed > 1.0
        else
            # Should return without waiting out the 4s handler — and does not,
            # on Nghttp2Wrapper 0.3.0. Its `close` submits GOAWAY under the
            # connection lock, which the connection task holds for the whole
            # duration of a running handler, so `timeout = 0` blocks for exactly
            # as long as the handler. Measured: 4.21s.
            #
            # Fixed upstream (the GOAWAY lock wait is now bounded), unreleased.
            # `@test_broken` rather than a relaxed bound so that Test.jl reports
            # "Unexpectedly Passed" the moment the pin can be raised, instead of
            # this quietly staying wrong.
            @test_broken elapsed < 3.0
        end
        @test elapsed < 30.0

        nghttp2_session_del(session)
        close(cb)
        try; close(sock); catch; end
    end
end

# --- Security: receive path (SEC_ROADMAP phase 2, Nghttp2Backend) -----------
#
# These live here rather than in test/security/ because Nghttp2Wrapper cannot
# join the default test environment (see the header note). They mirror the
# receive-path assertions the other two backends get in
# test/security/test_framing_adversarial.jl.
#
# Both defects covered here were real: `read_message!` had no size cap at all,
# and it read the compression flag and then ignored it, handing the handler
# still-compressed bytes that the protobuf decoder parsed as if they were the
# request — a silently wrong result rather than an error.

@testset "Security: Nghttp2 receive path" begin
    NExt = Base.get_extension(gRPCServer, :gRPCServerNghttp2Ext)
    @test NExt !== nothing

    _frame(payload; compressed = false) =
        vcat(UInt8[compressed ? 0x01 : 0x00],
             reinterpret(UInt8, [hton(UInt32(length(payload)))]), payload)

    function _stream(body; encoding = "gzip", cap = 4 * 1024 * 1024)
        headers = Nghttp2Wrapper.NVPair[
            Nghttp2Wrapper.NVPair("content-type", "application/grpc")]
        encoding === nothing ||
            push!(headers, Nghttp2Wrapper.NVPair("grpc-encoding", encoding))
        req = Nghttp2Wrapper.ServerRequest("POST", "/t/M", headers, body, Int32(1))
        return NExt.Nghttp2GRPCStream(req, cap)
    end

    _err(f) = try
        f()
        nothing
    catch e
        e
    end

    @testset "Over-cap message is refused" begin
        # 8 MiB against the 4 MiB default.
        err = _err(() -> gRPCServer.read_message!(
            _stream(_frame(rand(UInt8, 8 * 1024 * 1024)))))
        @test err isa gRPCServer.GRPCError
        @test err.code == gRPCServer.StatusCode.RESOURCE_EXHAUSTED
    end

    @testset "Message under the cap still passes" begin
        payload = rand(UInt8, 1024)
        msg = gRPCServer.read_message!(_stream(_frame(payload)))
        @test msg !== nothing
        @test read(msg) == payload
    end

    @testset "Compressed frames are decompressed, not passed through" begin
        original = Vector{UInt8}("hello gRPC compressed")
        comp = gRPCServer.compress(original, gRPCServer.CompressionCodec.GZIP)
        got = read(gRPCServer.read_message!(_stream(_frame(comp; compressed = true))))
        @test got == original
        @test got != comp        # the defect this pins
    end

    @testset "Compressed frame with no usable codec is UNIMPLEMENTED" begin
        comp = gRPCServer.compress(Vector{UInt8}("x"), gRPCServer.CompressionCodec.GZIP)
        for encoding in (nothing, "br")
            err = _err(() -> gRPCServer.read_message!(
                _stream(_frame(comp; compressed = true); encoding = encoding)))
            @test err isa gRPCServer.GRPCError
            @test err.code == gRPCServer.StatusCode.UNIMPLEMENTED
        end
    end

    @testset "Decompression bomb is refused" begin
        bomb = gRPCServer.compress(zeros(UInt8, 32 * 1024 * 1024),
                                   gRPCServer.CompressionCodec.GZIP)
        cap = 1024 * 1024
        @test length(bomb) < cap          # clears the length-prefix check
        err = _err(() -> gRPCServer.read_message!(
            _stream(_frame(bomb; compressed = true); cap = cap)))
        @test err isa gRPCServer.GRPCError
        @test err.code == gRPCServer.StatusCode.RESOURCE_EXHAUSTED
    end

    @testset "Capabilities report what the backend now does" begin
        caps = gRPCServer.backend_capabilities(Nghttp2Backend)
        @test caps.receive_cap
        @test caps.decompression
        # max_receive_message_length is honoured, so it must no longer raise.
        @test GRPCServer("127.0.0.1", 50051; http2_backend = Nghttp2Backend(),
                         max_receive_message_length = 1024 * 1024) isa GRPCServer
    end
end

# The opposite case for the OTHER optional backend: this environment has no
# PureHTTP2, so it proves the extension is absent and the guard is actionable.
@testset "PureHTTP2 extension absent" begin
    @test Base.get_extension(gRPCServer, :gRPCServerPureHTTP2Ext) === nothing
    err = try
        PureHTTP2Backend()
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("using PureHTTP2", sprint(showerror, err))

    # The default backend still serves in a PureHTTP2-free environment.
    @test gRPCServer.uses_serve_grpc(HTTPjlBackend())
    @test GRPCServer("127.0.0.1", 50123).http2_backend isa HTTPjlBackend
end
