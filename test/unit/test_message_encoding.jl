# AC3: Message Encoding Tests
# Tests per gRPC HTTP/2 Protocol Specification
# Reference: https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md

using Test
using gRPCServer

# Include test utilities if not already loaded
if !isdefined(@__MODULE__, :TestUtils)
    include("../TestUtils.jl")
    using .TestUtils
end

# Include conformance test data
# Guarded: nine test files load this module and runtests.jl includes them all
# into the same namespace, so an unguarded include redefines it and Julia prints
# "WARNING: replacing module ConformanceData" once per extra include.
if !isdefined(@__MODULE__, :ConformanceData)
    include("../fixtures/conformance_data.jl")
end
using .ConformanceData

@testset "AC3: Message Encoding" begin

    # =========================================================================
    # T021: Length-Prefixed Message Format
    # =========================================================================

    @testset "T021: Length-prefixed message format" begin

        @testset "Build message: 1 byte flag + 4 bytes length + data" begin
            data = UInt8[0x01, 0x02, 0x03, 0x04, 0x05]
            msg = TestUtils.build_grpc_message(data)

            # Total: 1 + 4 + 5 = 10 bytes
            @test length(msg) == 10

            # Compressed flag (byte 1)
            @test msg[1] == 0x00  # Not compressed

            # Length in big-endian (bytes 2-5)
            @test msg[2] == 0x00
            @test msg[3] == 0x00
            @test msg[4] == 0x00
            @test msg[5] == 0x05

            # Data (bytes 6-10)
            @test msg[6:10] == data
        end

        @testset "Build empty message" begin
            data = UInt8[]
            msg = TestUtils.build_grpc_message(data)

            @test length(msg) == 5  # Just header
            @test msg[1] == 0x00
            @test msg[2] == 0x00
            @test msg[3] == 0x00
            @test msg[4] == 0x00
            @test msg[5] == 0x00
        end

        @testset "Build large message (256 bytes)" begin
            data = zeros(UInt8, 256)
            msg = TestUtils.build_grpc_message(data)

            @test length(msg) == 5 + 256

            # Length = 256 = 0x00000100
            @test msg[2] == 0x00
            @test msg[3] == 0x00
            @test msg[4] == 0x01
            @test msg[5] == 0x00
        end

    end  # T021

    # =========================================================================
    # T022: Compressed Flag
    # =========================================================================

    @testset "T022: Compressed flag" begin

        @testset "Uncompressed message: flag = 0" begin
            data = UInt8[0xAA, 0xBB, 0xCC]
            msg = TestUtils.build_grpc_message(data; compressed=false)
            @test msg[1] == 0x00
        end

        @testset "Compressed message: flag = 1" begin
            data = UInt8[0xAA, 0xBB, 0xCC]
            msg = TestUtils.build_grpc_message(data; compressed=true)
            @test msg[1] == 0x01
        end

        @testset "Parse compressed flag" begin
            # Uncompressed
            msg_uncomp = UInt8[0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03]
            compressed, _ = TestUtils.parse_grpc_message(msg_uncomp)
            @test !compressed

            # Compressed
            msg_comp = UInt8[0x01, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03]
            compressed, _ = TestUtils.parse_grpc_message(msg_comp)
            @test compressed
        end

    end  # T022

    # =========================================================================
    # T023: Message Length Encoding (Big-Endian)
    # =========================================================================

    @testset "T023: Message length big-endian encoding" begin

        @testset "Small message length" begin
            data = UInt8[0x01]  # 1 byte
            msg = TestUtils.build_grpc_message(data)
            # Length = 1 = 0x00000001
            @test msg[2:5] == UInt8[0x00, 0x00, 0x00, 0x01]
        end

        @testset "Medium message length (1024 bytes)" begin
            data = zeros(UInt8, 1024)
            msg = TestUtils.build_grpc_message(data)
            # Length = 1024 = 0x00000400
            @test msg[2:5] == UInt8[0x00, 0x00, 0x04, 0x00]
        end

        @testset "Large message length (65536 bytes)" begin
            data = zeros(UInt8, 65536)
            msg = TestUtils.build_grpc_message(data)
            # Length = 65536 = 0x00010000
            @test msg[2:5] == UInt8[0x00, 0x01, 0x00, 0x00]
        end

        @testset "Parse length correctly" begin
            # Message with length = 256
            msg = vcat(UInt8[0x00, 0x00, 0x00, 0x01, 0x00], zeros(UInt8, 256))
            _, data = TestUtils.parse_grpc_message(msg)
            @test length(data) == 256
        end

    end  # T023

    # =========================================================================
    # T024: Message Round-Trip
    # =========================================================================

    @testset "T024: Message encode/decode round-trip" begin

        @testset "Round-trip small message" begin
            original = UInt8[0x01, 0x02, 0x03, 0x04, 0x05]
            encoded = TestUtils.build_grpc_message(original)
            _, decoded = TestUtils.parse_grpc_message(encoded)
            @test decoded == original
        end

        @testset "Round-trip empty message" begin
            original = UInt8[]
            encoded = TestUtils.build_grpc_message(original)
            _, decoded = TestUtils.parse_grpc_message(encoded)
            @test decoded == original
        end

        @testset "Round-trip compressed flag" begin
            original = UInt8[0xAA, 0xBB]
            encoded = TestUtils.build_grpc_message(original; compressed=true)
            compressed, decoded = TestUtils.parse_grpc_message(encoded)
            @test compressed
            @test decoded == original
        end

        @testset "Round-trip binary data" begin
            original = Vector{UInt8}(0:255)
            encoded = TestUtils.build_grpc_message(original)
            _, decoded = TestUtils.parse_grpc_message(encoded)
            @test decoded == original
        end

    end  # T024

    # =========================================================================
    # T025: Invalid Message Handling
    # =========================================================================

    @testset "T025: Invalid message handling" begin

        @testset "Message too short (< 5 bytes)" begin
            @test_throws Exception TestUtils.parse_grpc_message(UInt8[0x00])
            @test_throws Exception TestUtils.parse_grpc_message(UInt8[0x00, 0x00, 0x00])
        end

        @testset "Truncated message" begin
            # Header says 5 bytes but only 2 bytes of data
            msg = UInt8[0x00, 0x00, 0x00, 0x00, 0x05, 0x01, 0x02]
            @test_throws Exception TestUtils.parse_grpc_message(msg)
        end

        @testset "Conformance test cases for invalid messages" begin
            for (input, _, _, _, should_fail) in ConformanceData.MESSAGE_FRAME_TEST_CASES
                if should_fail
                    @test_throws Exception TestUtils.parse_grpc_message(input)
                end
            end
        end

    end  # T025

    # =========================================================================
    # T026: Compression Codec Integration
    # =========================================================================

    @testset "T026: Compression codec integration" begin

        @testset "GZIP compress/decompress" begin
            original = Vector{UInt8}("Hello, gRPC compression test! " ^ 10)
            compressed = gRPCServer.compress(original, CompressionCodec.GZIP)
            decompressed = gRPCServer.decompress(compressed, CompressionCodec.GZIP)
            @test decompressed == original
            @test length(compressed) < length(original)  # Should compress
        end

        @testset "DEFLATE compress/decompress" begin
            original = Vector{UInt8}("Test data for deflate compression")
            compressed = gRPCServer.compress(original, CompressionCodec.DEFLATE)
            decompressed = gRPCServer.decompress(compressed, CompressionCodec.DEFLATE)
            @test decompressed == original
        end

        @testset "IDENTITY codec is no-op" begin
            original = UInt8[0x01, 0x02, 0x03]
            @test gRPCServer.compress(original, CompressionCodec.IDENTITY) == original
            @test gRPCServer.decompress(original, CompressionCodec.IDENTITY) == original
        end

        @testset "Parse grpc-encoding header" begin
            @test gRPCServer.parse_codec("gzip") == CompressionCodec.GZIP
            @test gRPCServer.parse_codec("deflate") == CompressionCodec.DEFLATE
            @test gRPCServer.parse_codec("identity") == CompressionCodec.IDENTITY
            @test gRPCServer.parse_codec("unknown") === nothing
        end

        @testset "Parse grpc-accept-encoding header" begin
            codecs = gRPCServer.parse_accept_encoding("gzip, deflate, identity")
            @test CompressionCodec.GZIP in codecs
            @test CompressionCodec.DEFLATE in codecs
            @test CompressionCodec.IDENTITY in codecs
        end

        @testset "Negotiate compression" begin
            client_codecs = [CompressionCodec.GZIP, CompressionCodec.DEFLATE]
            server_codecs = [CompressionCodec.DEFLATE, CompressionCodec.GZIP]
            result = gRPCServer.negotiate_compression(client_codecs, server_codecs)
            @test result == CompressionCodec.GZIP  # First match from client preference

            # No common codec
            empty_server = CompressionCodec.T[]
            result = gRPCServer.negotiate_compression(client_codecs, empty_server)
            @test result == CompressionCodec.IDENTITY  # Fallback
        end

    end  # T026

    # =========================================================================
    # T026b: read_grpc_message! with compression (coverage)
    # =========================================================================

    @testset "T026b: read_grpc_message! decompression" begin

        @testset "Decompress gzip message" begin
            # Create stream with grpc-encoding header
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "gzip"),
            ]

            # Create compressed message
            original = Vector{UInt8}("Hello, gRPC!")
            compressed_data = gRPCServer.compress(original, CompressionCodec.GZIP)

            # Build length-prefixed message with compressed flag = 1
            msg = vcat(
                UInt8[0x01],  # Compressed flag
                reinterpret(UInt8, [hton(UInt32(length(compressed_data)))]),
                compressed_data
            )

            # Write to stream buffer
            write(stream.data_buffer, msg)

            # Read and verify decompression
            result = P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream)
            @test result !== nothing
            @test result == original
        end

        @testset "Decompress deflate message" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "deflate"),
            ]

            original = Vector{UInt8}("Deflate test data")
            compressed_data = gRPCServer.compress(original, CompressionCodec.DEFLATE)

            msg = vcat(
                UInt8[0x01],
                reinterpret(UInt8, [hton(UInt32(length(compressed_data)))]),
                compressed_data
            )
            write(stream.data_buffer, msg)

            result = P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream)
            @test result !== nothing
            @test result == original
        end

        @testset "Identity encoding with compressed flag" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "identity"),
            ]

            original = UInt8[0x01, 0x02, 0x03]
            msg = vcat(
                UInt8[0x01],  # Compressed flag set
                reinterpret(UInt8, [hton(UInt32(length(original)))]),
                original
            )
            write(stream.data_buffer, msg)

            # With identity encoding, data should pass through unchanged
            result = P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream)
            @test result !== nothing
            @test result == original
        end

        @testset "Compressed flag set but no grpc-encoding header" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                # No grpc-encoding header
            ]

            data = UInt8[0x01, 0x02, 0x03]
            msg = vcat(
                UInt8[0x01],  # Compressed flag set
                reinterpret(UInt8, [hton(UInt32(length(data)))]),
                data
            )
            write(stream.data_buffer, msg)

            # A compressed frame with no negotiated encoding is a protocol
            # violation, not something to pass through: returning the still-
            # compressed bytes would hand the handler garbage to decode as if it
            # were the request. Matches src/framing.jl (the HTTPjl path).
            err = try
                P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream)
                nothing
            catch e
                e
            end
            @test err isa gRPCServer.GRPCError
            @test err.code == gRPCServer.StatusCode.UNIMPLEMENTED
        end

        @testset "Unknown encoding codec" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "unknown-codec"),
            ]

            data = UInt8[0x01, 0x02, 0x03]
            msg = vcat(
                UInt8[0x01],
                reinterpret(UInt8, [hton(UInt32(length(data)))]),
                data
            )
            write(stream.data_buffer, msg)

            # An unsupported grpc-encoding is refused rather than passed through,
            # for the same reason as the missing-header case above.
            err = try
                P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream)
                nothing
            catch e
                e
            end
            @test err isa gRPCServer.GRPCError
            @test err.code == gRPCServer.StatusCode.UNIMPLEMENTED
        end

        @testset "Uncompressed message (flag = 0)" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "gzip"),  # Header present but flag is 0
            ]

            data = UInt8[0xAA, 0xBB, 0xCC]
            msg = vcat(
                UInt8[0x00],  # Not compressed
                reinterpret(UInt8, [hton(UInt32(length(data)))]),
                data
            )
            write(stream.data_buffer, msg)

            # Should not attempt decompression
            result = P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream)
            @test result !== nothing
            @test result == data
        end

        # --- Receive-cap enforcement (security regression tests) -------------
        #
        # These cover the two ways a peer can force unbounded memory on this
        # backend. Both were unenforced: read_grpc_message! had no cap, and it
        # decompressed through the uncapped `decompress` rather than the
        # output-capped `_decompress_frame`.

        @testset "Over-cap length prefix is refused" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"), (":path", "/test/Method"),
                ("content-type", "application/grpc"),
            ]
            # Declare far more than the cap; send no payload. The frame must be
            # refused on the prefix alone, without waiting for the bytes.
            write(stream.data_buffer,
                  vcat(UInt8[0x00], reinterpret(UInt8, [hton(UInt32(10_000_000))])))
            cap = 1024

            # Reported "ready" so the stream is dispatched and refused rather
            # than buffering while it waits for a payload it will never accept.
            @test P2Ext.has_complete_grpc_message(stream, cap)

            err = try
                P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream, cap)
                nothing
            catch e
                e
            end
            @test err isa gRPCServer.GRPCError
            @test err.code == gRPCServer.StatusCode.RESOURCE_EXHAUSTED
        end

        @testset "Decompression bomb is refused" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"), (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "gzip"),
            ]
            # ~1000:1 under gzip: a payload that clears the length-prefix check
            # but expands far past the cap once decompressed.
            bomb = gRPCServer.compress(zeros(UInt8, 16 * 1024 * 1024), CompressionCodec.GZIP)
            cap = 1024 * 1024
            @test length(bomb) < cap  # passes the prefix check
            write(stream.data_buffer,
                  vcat(UInt8[0x01], reinterpret(UInt8, [hton(UInt32(length(bomb)))]), bomb))

            err = try
                P2Ext.read_grpc_message!(PureHTTP2.HTTP2Connection(), stream, cap)
                nothing
            catch e
                e
            end
            @test err isa gRPCServer.GRPCError
            @test err.code == gRPCServer.StatusCode.RESOURCE_EXHAUSTED
        end

        @testset "Honest compressed message under the cap still round-trips" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.request_headers = [
                (":method", "POST"), (":path", "/test/Method"),
                ("content-type", "application/grpc"),
                ("grpc-encoding", "gzip"),
            ]
            original = Vector{UInt8}("a real request payload")
            comp = gRPCServer.compress(original, CompressionCodec.GZIP)
            write(stream.data_buffer,
                  vcat(UInt8[0x01], reinterpret(UInt8, [hton(UInt32(length(comp)))]), comp))
            @test P2Ext.read_grpc_message!(
                PureHTTP2.HTTP2Connection(), stream, 1024 * 1024) == original
        end

    end  # T026b

end  # AC3: Message Encoding
