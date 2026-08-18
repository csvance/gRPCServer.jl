# AC2: Response Format Tests
# Tests per gRPC HTTP/2 Protocol Specification
# Reference: https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md

using Test
using gRPCServer
using Base64

# Include conformance test data
# Guarded: nine test files load this module and runtests.jl includes them all
# into the same namespace, so an unguarded include redefines it and Julia prints
# "WARNING: replacing module ConformanceData" once per extra include.
if !isdefined(@__MODULE__, :ConformanceData)
    include("../fixtures/conformance_data.jl")
end
using .ConformanceData

@testset "AC2: Response Format" begin

    # =========================================================================
    # T015: HTTP Status 200 Required
    # =========================================================================

    @testset "T015: HTTP status must be 200" begin

        @testset "Valid response with HTTP 200" begin
            valid, _ = TestUtils.validate_grpc_response(status=200, grpc_status=0)
            @test valid
        end

        @testset "Invalid response with HTTP 400" begin
            valid, msg = TestUtils.validate_grpc_response(status=400, grpc_status=3)
            @test !valid
            @test occursin("200", msg)
        end

        @testset "Invalid response with HTTP 500" begin
            valid, _ = TestUtils.validate_grpc_response(status=500, grpc_status=13)
            @test !valid
        end

        @testset "All HTTP status codes except 200 invalid" begin
            for status in [201, 204, 301, 302, 400, 401, 403, 404, 500, 502, 503]
                valid, _ = TestUtils.validate_grpc_response(status=status, grpc_status=0)
                @test !valid
            end
        end

    end  # T015

    # =========================================================================
    # T016: Response Content-Type
    # =========================================================================

    @testset "T016: Response content-type" begin

        @testset "Valid: application/grpc" begin
            valid, _ = TestUtils.validate_grpc_response(
                status=200,
                content_type="application/grpc",
                grpc_status=0
            )
            @test valid
        end

        @testset "Valid: application/grpc+proto" begin
            valid, _ = TestUtils.validate_grpc_response(
                status=200,
                content_type="application/grpc+proto",
                grpc_status=0
            )
            @test valid
        end

        @testset "Invalid: application/json" begin
            valid, _ = TestUtils.validate_grpc_response(
                status=200,
                content_type="application/json",
                grpc_status=0
            )
            @test !valid
        end

    end  # T016

    # =========================================================================
    # T017: Trailers with grpc-status
    # =========================================================================

    @testset "T017: grpc-status in trailers" begin

        @testset "Valid: grpc-status 0 (OK)" begin
            valid, _ = TestUtils.validate_grpc_response(status=200, grpc_status=0)
            @test valid
        end

        @testset "All valid gRPC status codes" begin
            for code in 0:16
                valid, _ = TestUtils.validate_grpc_response(status=200, grpc_status=code)
                @test valid
            end
        end

        @testset "Invalid: grpc-status > 16" begin
            valid, msg = TestUtils.validate_grpc_response(status=200, grpc_status=17)
            @test !valid
            @test occursin("grpc-status", msg)
        end

        @testset "Invalid: negative grpc-status" begin
            valid, _ = TestUtils.validate_grpc_response(status=200, grpc_status=-1)
            @test !valid
        end

    end  # T017

    # =========================================================================
    # T018: grpc-message Encoding
    # =========================================================================

    @testset "T018: grpc-message encoding" begin

        # `percent_encode` (src/strict.jl) is the ONE grpc-message encoder. A
        # second, unused, byte-incorrect variant (`HTTP_urlencode`) used to sit
        # in src/context.jl and was pinned by these tests; it was removed. The
        # cases below include the two it got wrong, so a reintroduction fails
        # here rather than on the wire.

        @testset "Encoding function exists" begin
            @test isdefined(gRPCServer, :percent_encode)
        end

        @testset "Printable ASCII passes through unescaped" begin
            # Per the gRPC spec the escaped set is bytes outside 0x20..0x7E plus
            # '%' — NOT the RFC 3986 unreserved set. Spaces and ':' stay literal.
            @test gRPCServer.percent_encode("Hello World") == "Hello World"
            @test gRPCServer.percent_encode("Test: value=123") == "Test: value=123"
            @test gRPCServer.percent_encode("abcABC123-._~") == "abcABC123-._~"
        end

        @testset "Control bytes and percent are escaped" begin
            @test gRPCServer.percent_encode("a\nb") == "a%0Ab"
            @test gRPCServer.percent_encode("tab\there") == "tab%09here"
            @test gRPCServer.percent_encode("100%") == "100%25"
        end

        @testset "Non-ASCII is escaped as UTF-8 bytes" begin
            # The removed encoder produced "caf%E9" here (truncated code point)
            # and threw InexactError on anything above U+00FF.
            @test gRPCServer.percent_encode("café") == "caf%C3%A9"
            @test gRPCServer.percent_encode("日本語") == "%E6%97%A5%E6%9C%AC%E8%AA%9E"
            @test gRPCServer.percent_encode("→") == "%E2%86%92"
            @test gRPCServer.percent_encode("emoji 🚀") == "emoji %F0%9F%9A%80"
        end

        @testset "Response trailers include grpc-message" begin
            ctx = gRPCServer.ServerContext()
            trailers = gRPCServer.get_response_trailers(ctx, 3, "Invalid argument")

            has_status = false
            has_message = false
            for (name, value) in trailers
                if name == "grpc-status"
                    @test value == "3"
                    has_status = true
                elseif name == "grpc-message"
                    has_message = true
                end
            end
            @test has_status
            @test has_message
        end

    end  # T018

    # =========================================================================
    # T019: Trailers-Only Response
    # =========================================================================

    @testset "T019: Trailers-only response" begin

        @testset "Trailers-only response format" begin
            # Trailers-only: headers contain both :status and grpc-status
            collector = TestUtils.MockResponseCollector()
            TestUtils.parse_response_headers!(collector, [
                (":status", "200"),
                ("content-type", "application/grpc"),
                ("grpc-status", "12"),  # UNIMPLEMENTED
                ("grpc-message", "Method%20not%20found"),
            ])

            @test collector.http_status == 200
            @test collector.grpc_status == 12
            @test collector.grpc_message == "Method%20not%20found"
        end

        @testset "Trailers-only valid for immediate errors" begin
            # For immediate errors (UNIMPLEMENTED, INVALID_ARGUMENT, etc.)
            # server can respond with trailers-only format
            collector = TestUtils.MockResponseCollector()
            TestUtils.parse_response_headers!(collector, [
                (":status", "200"),
                ("content-type", "application/grpc"),
                ("grpc-status", "3"),
                ("grpc-message", "Missing required field"),
            ])

            @test collector.grpc_status == 3  # INVALID_ARGUMENT
        end

    end  # T019

    # =========================================================================
    # T020: Response Headers Format
    # =========================================================================

    @testset "T020: Response headers format" begin

        @testset "Context generates proper response headers" begin
            ctx = gRPCServer.ServerContext()
            gRPCServer.set_header!(ctx, "x-custom-header", "custom-value")

            headers = gRPCServer.get_response_headers(ctx)
            found = false
            for (name, value) in headers
                if name == "x-custom-header"
                    @test value == "custom-value"
                    found = true
                end
            end
            @test found
        end

        @testset "Binary headers are base64 encoded" begin
            ctx = gRPCServer.ServerContext()
            binary_data = UInt8[0x01, 0x02, 0x03, 0x04]
            gRPCServer.set_header!(ctx, "x-binary-bin", binary_data)

            headers = gRPCServer.get_response_headers(ctx)
            for (name, value) in headers
                if name == "x-binary-bin"
                    # Should be base64 encoded
                    @test value isa String
                    @test Base64.base64decode(value) == binary_data
                end
            end
        end

        @testset "Response trailers format" begin
            ctx = gRPCServer.ServerContext()
            gRPCServer.set_trailer!(ctx, "x-processing-time", "150ms")

            trailers = gRPCServer.get_response_trailers(ctx, 0, "")

            # Should contain grpc-status
            has_status = any(name == "grpc-status" for (name, _) in trailers)
            @test has_status

            # Should contain custom trailer
            has_custom = false
            for (name, value) in trailers
                if name == "x-processing-time"
                    @test value == "150ms"
                    has_custom = true
                end
            end
            @test has_custom
        end

    end  # T020

end  # AC2: Response Format
