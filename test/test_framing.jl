@testset "Framing" begin
    using gRPCServer: grpc_encode_message_iobuffer, GRPC_HEADER_SIZE
    using ProtoBuf: ProtoDecoder, decode

    # Encode a message and verify the 5-byte length-prefixed framing.
    msg = TestResponse(collect(UInt64, 1:7))
    buf = grpc_encode_message_iobuffer(msg)
    bytes = take!(buf)

    @test length(bytes) >= GRPC_HEADER_SIZE
    @test bytes[1] == 0x00  # uncompressed flag

    # Big-endian UInt32 length prefix equals the payload size.
    declared =
        (UInt32(bytes[2]) << 24) |
        (UInt32(bytes[3]) << 16) |
        (UInt32(bytes[4]) << 8) |
        UInt32(bytes[5])
    payload = bytes[(GRPC_HEADER_SIZE+1):end]
    @test declared == length(payload)

    # Payload decodes back to the original message.
    roundtrip = decode(ProtoDecoder(IOBuffer(payload)), TestResponse)
    @test roundtrip.data == msg.data

    # Empty message is valid: a 5-byte frame with length 0.
    empty_bytes = take!(grpc_encode_message_iobuffer(TestResponse(UInt64[])))
    @test length(empty_bytes) == GRPC_HEADER_SIZE
    @test empty_bytes[2:5] == zeros(UInt8, 4)

    # Oversize message is rejected.
    @test_throws gRPCServiceCallException grpc_encode_message_iobuffer(
        TestResponse(collect(UInt64, 1:1000));
        max_send_message_length = 16,
    )
end
