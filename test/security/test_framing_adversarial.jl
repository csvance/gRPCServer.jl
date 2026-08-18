# Adversarial framing and decompression tests (SEC_ROADMAP phases 2a and 2b).
#
# These exercise the receive path from the point of view of a hostile peer: the
# bytes are fully attacker-controlled, and the invariant under test is that every
# malformed or oversized input yields a `GRPCError` with a sensible status —
# never an unbounded allocation, never a hang, never a non-gRPC exception
# escaping to the connection loop.

using Test
using gRPCServer
using gRPCServer: FrameReader, read_message!, expect_half_close!, GRPCError,
                  StatusCode, CompressionCodec, compress, _decompress_frame

# Build a raw gRPC frame with an arbitrary declared length, so the declared and
# actual sizes can be made to disagree.
function frame(payload::Vector{UInt8}; compressed::Bool = false, declared = nothing)
    n = UInt32(declared === nothing ? length(payload) : declared)
    return vcat(UInt8[compressed ? 0x01 : 0x00],
                reinterpret(UInt8, [hton(n)]),
                payload)
end

reader(bytes::Vector{UInt8}; cap = 4 * 1024 * 1024, encoding = nothing) =
    FrameReader(IOBuffer(bytes), cap, encoding)

# Run `f`, returning the GRPCError it threw, or `nothing` if it did not throw.
function grpc_error(f)
    try
        f()
        return nothing
    catch e
        e isa GRPCError && return e
        rethrow()
    end
end

@testset "Security: adversarial framing" begin

    @testset "Length prefix at the UInt32 ceiling is refused, not allocated" begin
        # The classic shape: a 5-byte frame declaring ~4 GiB. Refusing on the
        # prefix alone is what keeps this cheap; the peer sends no payload at all.
        for declared in (typemax(UInt32), typemax(UInt32) - 1, UInt32(1) << 31)
            err = grpc_error(() -> read_message!(
                reader(frame(UInt8[]; declared = declared); cap = 1024)))
            @test err !== nothing
            @test err.code == StatusCode.RESOURCE_EXHAUSTED
        end
    end

    @testset "Boundaries of max_receive_message_length" begin
        cap = 1024
        # Exactly at the cap: accepted.
        at = fill(0x41, cap)
        @test read_message!(reader(frame(at); cap = cap)) !== nothing
        # One byte over: refused.
        err = grpc_error(() -> read_message!(reader(frame(fill(0x41, cap + 1)); cap = cap)))
        @test err !== nothing && err.code == StatusCode.RESOURCE_EXHAUSTED
    end

    @testset "Truncated frames are INVALID_ARGUMENT, not EOF or hang" begin
        # Header cut mid-way.
        err = grpc_error(() -> read_message!(reader(UInt8[0x00, 0x00, 0x00])))
        @test err !== nothing && err.code == StatusCode.INVALID_ARGUMENT

        # Full header, payload shorter than declared.
        err = grpc_error(() -> read_message!(
            reader(frame(UInt8[0x01, 0x02]; declared = 64))))
        @test err !== nothing && err.code == StatusCode.INVALID_ARGUMENT
    end

    @testset "A clean half-close is not an error" begin
        @test read_message!(reader(UInt8[])) === nothing
    end

    @testset "Empty frame is a valid zero-length message" begin
        buf = read_message!(reader(frame(UInt8[])))
        @test buf !== nothing
        @test isempty(read(buf))
    end

    @testset "Compressed flag with no negotiated encoding is UNIMPLEMENTED" begin
        # Rejected before the payload is buffered, so a bare header cannot make
        # the server do work on the strength of a flag alone.
        err = grpc_error(() -> read_message!(
            reader(frame(UInt8[0x01, 0x02]; compressed = true))))
        @test err !== nothing && err.code == StatusCode.UNIMPLEMENTED
    end

    @testset "Compressed flag with an unsupported encoding is UNIMPLEMENTED" begin
        err = grpc_error(() -> read_message!(
            reader(frame(UInt8[0x01]; compressed = true); encoding = "br")))
        @test err !== nothing && err.code == StatusCode.UNIMPLEMENTED
    end

    @testset "A single-message RPC refuses a flood of extra frames" begin
        # expect_half_close! must reject rather than drain: draining an endless
        # run of frames would pin the handler task for as long as the peer keeps
        # writing.
        body = vcat(frame(UInt8[0x01]), (frame(UInt8[0x02]) for _ in 1:10_000)...)
        fr = reader(body)
        @test read_message!(fr) !== nothing
        err = grpc_error(() -> expect_half_close!(fr))
        @test err !== nothing && err.code == StatusCode.INVALID_ARGUMENT
    end
end

@testset "Security: decompression bombs" begin

    # gzip/deflate cap out around 1000:1, so these ratios are what a real peer
    # can actually achieve — not a synthetic worst case.
    @testset "High-ratio payloads are refused at the cap, in bounded time" begin
        cap = Int64(64 * 1024)
        for raw_size in (1 * 1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024)
            for codec in (CompressionCodec.GZIP, CompressionCodec.DEFLATE)
                bomb = compress(zeros(UInt8, raw_size), codec)
                @test length(bomb) < cap          # clears any length-prefix check
                err = grpc_error(() -> _decompress_frame(bomb, codec, cap))
                @test err !== nothing
                @test err.code == StatusCode.RESOURCE_EXHAUSTED
            end
        end
    end

    @testset "Bomb refused through the full FrameReader path" begin
        cap = 64 * 1024
        bomb = compress(zeros(UInt8, 32 * 1024 * 1024), CompressionCodec.GZIP)
        err = grpc_error(() -> read_message!(
            reader(frame(bomb; compressed = true); cap = cap, encoding = "gzip")))
        @test err !== nothing && err.code == StatusCode.RESOURCE_EXHAUSTED
    end

    @testset "Corrupt and truncated compressed data is INTERNAL, not a crash" begin
        good = compress(Vector{UInt8}("a legitimate payload"), CompressionCodec.GZIP)

        # Truncated stream.
        err = grpc_error(() -> _decompress_frame(
            good[1:(length(good) ÷ 2)], CompressionCodec.GZIP, Int64(1024 * 1024)))
        @test err !== nothing && err.code == StatusCode.INTERNAL

        # Not compressed data at all.
        err = grpc_error(() -> _decompress_frame(
            Vector{UInt8}("not gzip at all"), CompressionCodec.GZIP, Int64(1024 * 1024)))
        @test err !== nothing && err.code == StatusCode.INTERNAL
    end

    @testset "Honest compressed traffic under the cap still round-trips" begin
        for codec in (CompressionCodec.GZIP, CompressionCodec.DEFLATE)
            original = Vector{UInt8}("a perfectly ordinary request payload")
            comp = compress(original, codec)
            @test _decompress_frame(comp, codec, Int64(1024 * 1024)) == original
        end

        original = Vector{UInt8}("through the reader")
        comp = compress(original, CompressionCodec.GZIP)
        buf = read_message!(reader(frame(comp; compressed = true); encoding = "gzip"))
        @test read(buf) == original
    end
end
