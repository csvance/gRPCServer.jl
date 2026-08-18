# Error-path coverage (SEC_ROADMAP phase 2f).
#
# Motivation, stated plainly: finding F-001 was a `throw` inside a `catch` block
# that no test ever reached, and which raised `UndefVarError` instead of the
# exception it was written to raise. The defect survived because the branch was
# never taken, not because it was subtle.
#
# So these tests are driven by coverage rather than by imagination: the suite was
# run under `--code-coverage`, every line inside a `catch` block or containing a
# `throw` with a zero hit count was listed, and the reachable ones are exercised
# here. Two properties are asserted for each: that the guard fires at all, and
# that it fires with the *declared* exception type — the part F-001 got wrong.
#
# The configuration guards are also the roadmap's exit criterion #2: every
# documented limit has a test that fails if the limit is removed.

using Test
using gRPCServer
using gRPCServer: ServerConfig, GRPCServer, ServerStatus, InvalidServerStateError,
                  UnsupportedFeatureError, start!, stop!

@testset "Security: error paths" begin

    @testset "Configuration guards reject values that would disable a limit" begin
        # Each of these bounds something an untrusted peer can push on. A guard
        # that silently accepted 0 or a negative value would leave the
        # corresponding limit inert — the shape of finding F-005, where a limit
        # was reported but not enforced.
        @test_throws ArgumentError ServerConfig(max_message_size = 0)
        @test_throws ArgumentError ServerConfig(max_message_size = -1)
        @test_throws ArgumentError ServerConfig(max_receive_message_length = 0)
        @test_throws ArgumentError ServerConfig(max_receive_message_length = -1)
        @test_throws ArgumentError ServerConfig(max_send_message_length = 0)
        @test_throws ArgumentError ServerConfig(max_concurrent_streams = 0)
        @test_throws ArgumentError ServerConfig(max_concurrent_streams = -1)
        @test_throws ArgumentError ServerConfig(max_header_bytes = 0)
        @test_throws ArgumentError ServerConfig(max_header_bytes = -1)
        @test_throws ArgumentError ServerConfig(backlog = 0)
        @test_throws ArgumentError ServerConfig(keepalive_timeout = 0.0)
        @test_throws ArgumentError ServerConfig(keepalive_timeout = -1.0)
        @test_throws ArgumentError ServerConfig(drain_timeout = 0.0)
        @test_throws ArgumentError ServerConfig(drain_timeout = -1.0)
        @test_throws ArgumentError ServerConfig(compression_threshold = -1)
    end

    @testset "Boundary values on the accepting side are accepted" begin
        # The guards must reject only what is genuinely out of range: a limit
        # that also refused its smallest legal value would push operators toward
        # larger caps than they intended.
        @test ServerConfig(max_message_size = 1).max_message_size == 1
        @test ServerConfig(max_concurrent_streams = 1).max_concurrent_streams == 1
        @test ServerConfig(max_header_bytes = 1).max_header_bytes == 1
        @test ServerConfig(backlog = 1).backlog == 1
        @test ServerConfig(compression_threshold = 0).compression_threshold == 0
    end

    @testset "Port bounds are enforced at construction" begin
        @test_throws ArgumentError GRPCServer("127.0.0.1", 0)
        @test_throws ArgumentError GRPCServer("127.0.0.1", -1)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 65536)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 100_000)
        # Both ends of the legal range.
        @test GRPCServer("127.0.0.1", 1).port == 1
        @test GRPCServer("127.0.0.1", 65535).port == 65535
    end

    @testset "Unknown keyword arguments are refused, not silently dropped" begin
        # A typo in a security-relevant keyword would otherwise leave the default
        # in force while the caller believes they configured something.
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50051; max_mesage_size = 1024)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50051; tls_config = nothing)
    end

    @testset "Lifecycle transitions raise the declared exception type" begin
        # `start!` only accepts STOPPED; `stop!` only accepts RUNNING/DRAINING,
        # and is deliberately idempotent from STOPPED.
        server = GRPCServer("127.0.0.1", 50051)

        @test server.status == ServerStatus.STOPPED
        @test stop!(server) === nothing          # idempotent, not an error

        for bad in (ServerStatus.STARTING, ServerStatus.RUNNING,
                    ServerStatus.DRAINING, ServerStatus.STOPPING)
            server.status = bad
            if bad in (ServerStatus.RUNNING, ServerStatus.DRAINING)
                # Accepted by stop!; start! must still refuse it.
                @test_throws InvalidServerStateError start!(server)
            else
                @test_throws InvalidServerStateError start!(server)
                @test_throws InvalidServerStateError stop!(server)
            end
        end
        server.status = ServerStatus.STOPPED
    end

    @testset "Backend capability violations raise UnsupportedFeatureError" begin
        # The mechanism that turns "silently ignored" into "refused at
        # construction". Finding F-005 was a hole in exactly this gate.
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50051; max_queued_requests = 10)
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50051; keepalive_interval = 10.0)
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50051; max_connections = 10)
    end

    @testset "TLSConfig guards" begin
        # Covered in depth by test_tls_adversarial.jl; repeated here as the
        # error-path inventory, since each is a zero-coverage throw.
        @test_throws ArgumentError gRPCServer.TLSConfig(
            cert_chain = "c", private_key = "k", require_client_cert = true)
        @test_throws ArgumentError gRPCServer.TLSConfig(
            cert_chain = "c", private_key = "k", min_version = :TLSv1_1)
        @test_throws ArgumentError gRPCServer.TLSConfig(
            cert_chain = "c", private_key = "k", alpn_protocols = String[])
        @test_throws ArgumentError gRPCServer.TLSConfig(
            cert_chain = "c", private_key = "k", handshake_timeout_ns = -1)
    end
end
