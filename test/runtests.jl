using Test
using gRPCServer

# Generate the TLS test fixtures if they are absent.
#
# test/fixtures/certs/ is gitignored, so a fresh checkout — every CI run — had no
# certificates and every TLS test silently skipped itself. That hid the whole TLS
# surface (ALPN negotiation, mTLS, certificate reload, the openssl/grpcurl interop
# suite) from CI while the jobs still reported success.
#
# Requires the openssl CLI; the generator warns and returns if it is missing, in
# which case the TLS tests skip as before.
# The generator guards its own entry point with `abspath(PROGRAM_FILE) == @__FILE__`,
# so including it only defines the function — it must be called explicitly.
if !isfile(joinpath(@__DIR__, "fixtures", "certs", "server.crt"))
    include(joinpath(@__DIR__, "fixtures", "generate_test_certs.jl"))
    generate_test_certificates()
end

# Include TestUtils module once for all tests to avoid method redefinition warnings
include("TestUtils.jl")
using .TestUtils

# PureHTTP2-dependent tests are OPT-IN (GRPCSERVER_TEST_PUREHTTP2=true):
# run via test/purehttp2/run_purehttp2_tests.jl and the `purehttp2` CI job.
# The default suite targets HTTPjlBackend (the default backend); the
# PureHTTP2 backend has known streaming-workload issues that are deliberately
# out of scope for 1.0 (tracked post-release), and its E2E serve path must not
# be able to hang the default suite.
const PUREHTTP2_TESTS = get(ENV, "GRPCSERVER_TEST_PUREHTTP2", "false") in ("true", "1")

@testset "gRPCServer.jl" begin
    # Aqua.jl quality checks
    include("aqua.jl")

    # Unit tests
    include("unit/test_config.jl")
    include("unit/test_errors.jl")
    include("unit/test_context.jl")
    include("unit/test_streams.jl")
    include("unit/test_interceptors.jl")
    include("unit/test_dispatch.jl")
    include("unit/test_compression.jl")
    include("unit/test_health.jl")
    include("unit/test_server.jl")
    include("unit/test_tls.jl")
    include("unit/test_tls_docs.jl")
    include("unit/test_reflection.jl")
    include("unit/test_response_format.jl")
    include("unit/test_error_mapping.jl")
    include("unit/test_dispatch_grpc_error_mapping.jl")
    include("unit/test_strict.jl")
    include("unit/test_timeout_handling.jl")

    # PureHTTP2-gated tests, wrapped in their own module.
    #
    # These files load PureHTTP2, which exports `get_metadata` and `set_header!`
    # — names gRPCServer exports too. Included straight into Main they made both
    # names ambiguous THERE, so unrelated tests that call them unqualified
    # (test_context.jl, test_metadata.jl, test_dispatch_grpc_error_mapping.jl)
    # failed with `UndefVarError` whenever the opt-in flag was set. The flag
    # therefore produced a wall of failures instead of coverage.
    #
    # A module confines the collision: PureHTTP2's exports are visible here and
    # nowhere else. Mirrors the CsvanceSuite pattern below. Each included file
    # already guards its own helper includes with `isdefined`, so they are
    # self-contained in this scope.
    if PUREHTTP2_TESTS
        @eval module PureHTTP2Suite
        using Test
        using gRPCServer
        using PureHTTP2          # loads gRPCServerPureHTTP2Ext
        using JSON
        using Sockets

        # Reuse the TestUtils instance Main already included, rather than
        # including it again here — a second copy would define a parallel set of
        # mock types that are not `===` to Main's.
        using ..TestUtils

        # The moved names (read_grpc_message!, get_response_content_type) are
        # reached through the extension module.
        const P2Ext = Base.get_extension(gRPCServer, :gRPCServerPureHTTP2Ext)
        P2Ext === nothing && error(
            "GRPCSERVER_TEST_PUREHTTP2 is set but gRPCServerPureHTTP2Ext did not load")

        include("unit/test_hpack.jl")
        include("unit/test_http2_stream.jl")
        include("unit/test_stream_state_validation.jl")
        include("unit/test_content_type.jl")
        include("unit/test_grpc_protocol.jl")
        include("unit/test_http2_conformance.jl")
        include("unit/test_request_validation.jl")
        include("unit/test_message_encoding.jl")
        include("unit/test_custom_metadata.jl")
        include("unit/test_connection_management.jl")
        include("unit/test_http2_backend.jl")
        include("backends/test_backend_interface.jl")
        include("interop/test_hpack_interop.jl")
        end
    end

    # Security tests: adversarial inputs from a hostile peer, and the response
    # metadata a handler is allowed to put on the wire (see SEC_ROADMAP).
    include("security/test_framing_adversarial.jl")
    include("security/test_response_metadata.jl")
    include("security/test_tls_adversarial.jl")
    include("security/test_resource_exhaustion.jl")
    include("security/test_error_paths.jl")

    # Fuzzing of the peer-controlled receive path. Runs a modest, deterministic
    # number of iterations here; raise GRPCSERVER_FUZZ_ITERATIONS for a campaign.
    include("fuzz/fuzz_receive_path.jl")

    # HTTP/2 backend tests (feature 020)
    include("backends/test_httpjl_backend.jl")
    include("backends/test_capability_validation.jl")

    # Integration tests
    include("integration/test_unary.jl")
    include("integration/test_server_streaming.jl")
    include("integration/test_client_streaming.jl")
    include("integration/test_bidi_streaming.jl")
    include("integration/test_errors.jl")
    include("integration/test_metadata.jl")
    include("integration/test_interceptors.jl")
    include("integration/test_health.jl")
    include("integration/test_tls.jl")
    include("integration/test_tls_interop.jl")

    # gRPCClient integration tests
    include("integration/test_grpcclient.jl")

    # The csvance suite, migrated to the merged API + the generated codegen
    # interface (the compat layer it used to run through was removed). Wrapped
    # in its own module so its TestRequest/TestResponse (from the regenerated
    # test/gen/test/test_pb.jl) do not collide with the s-celles suite's
    # Main.TestRequest/TestResponse (test/unit/test_reflection.jl defines those
    # at Main top level), and so `import gRPCClient` (no exports) avoids name
    # clashes with gRPCServer's exports.
    @eval module CsvanceSuite
    using Test, gRPCServer, HTTP, Sockets, Dates
    import gRPCClient
    import ProtoBuf
    using ProtoBuf: ProtoDecoder, ProtoEncoder, decode, encode
    include("gen/test/test_pb.jl")
    include("testservice.jl")
    include("test_codegen.jl")
    include("test_framing.jl")
    include("test_status.jl")
    include("test_unit.jl")
    include("test_integration.jl")
    include("test_errors.jl")
    include("test_lifecycle.jl")
    include("test_raw.jl")
    include("test_load.jl")
    end

    # Contract tests
    include("contract/test_grpcurl.jl")

    # Basic module tests
    @testset "Module loads correctly" begin
        @test isdefined(gRPCServer, :GRPCServer)
        @test isdefined(gRPCServer, :ServerConfig)
        @test isdefined(gRPCServer, :TLSConfig)
        @test isdefined(gRPCServer, :ServerContext)
        @test isdefined(gRPCServer, :ServiceDescriptor)
        @test isdefined(gRPCServer, :MethodDescriptor)
    end

    @testset "Enumerations" begin
        @test ServerStatus.STOPPED isa ServerStatus.T
        @test ServerStatus.RUNNING isa ServerStatus.T
        @test StatusCode.OK isa StatusCode.T
        @test StatusCode.INTERNAL isa StatusCode.T
        @test MethodType.UNARY isa MethodType.T
        @test MethodType.BIDI_STREAMING isa MethodType.T
        @test HealthStatus.SERVING isa HealthStatus.T
        @test CompressionCodec.GZIP isa CompressionCodec.T
    end

    @testset "ServerConfig" begin
        config = ServerConfig()
        @test config.max_message_size == 4 * 1024 * 1024
        @test config.max_concurrent_streams == 100
        @test config.enable_health_check == false
        @test config.debug_mode == false
    end

    @testset "TLSConfig" begin
        tls = TLSConfig(
            cert_chain = "/path/to/cert.pem",
            private_key = "/path/to/key.pem"
        )
        @test tls.cert_chain == "/path/to/cert.pem"
        @test tls.private_key == "/path/to/key.pem"
        @test tls.client_ca === nothing
        @test tls.require_client_cert == false
        @test tls.min_version == :TLSv1_2
    end

    @testset "GRPCError" begin
        err = GRPCError(StatusCode.NOT_FOUND, "Resource not found")
        @test err.code == StatusCode.NOT_FOUND
        @test err.message == "Resource not found"
        @test isempty(err.details)
    end

    @testset "Compression" begin
        @test codec_name(CompressionCodec.GZIP) == "gzip"
        @test codec_name(CompressionCodec.DEFLATE) == "deflate"
        @test codec_name(CompressionCodec.IDENTITY) == "identity"

        @test parse_codec("gzip") == CompressionCodec.GZIP
        @test parse_codec("deflate") == CompressionCodec.DEFLATE
        @test parse_codec("identity") == CompressionCodec.IDENTITY
        @test parse_codec("unknown") === nothing

        # Test compress/decompress round-trip
        data = Vector{UInt8}("Hello, gRPC!")
        compressed = compress(data, CompressionCodec.GZIP)
        decompressed = decompress(compressed, CompressionCodec.GZIP)
        @test decompressed == data
    end

    @testset "GRPCServer creation" begin
        server = GRPCServer("0.0.0.0", 50051)
        @test server.host == "0.0.0.0"
        @test server.port == 50051
        @test server.status == ServerStatus.STOPPED
        @test isempty(services(server))
    end

    @testset "GRPCServer with config" begin
        server = GRPCServer(
            "localhost", 8080;
            max_message_size = 8 * 1024 * 1024,
            enable_health_check = true,
            debug_mode = true
        )
        @test server.port == 8080
        @test server.config.max_message_size == 8 * 1024 * 1024
        @test server.config.enable_health_check == true
        @test server.config.debug_mode == true
    end
end
