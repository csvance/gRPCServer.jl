# Fuzzing harness for the peer-controlled receive path (SEC_ROADMAP phase 3).
#
# Every input here is fully attacker-controlled: request framing, the
# `grpc-timeout` header, and any text the server echoes back into a
# `grpc-message`. The harness asserts *invariants* rather than specific outputs,
# so it can explore inputs nobody thought to write down.
#
# Invariants under test:
#
#   1. FrameReader        — only `GRPCError` escapes; no hang; and the buffer
#                           grows with the bytes actually RECEIVED, never with
#                           the size the peer merely DECLARED.
#   2. parse_grpc_timeout — only `GRPCError` escapes, for arbitrary bytes
#                           (including invalid UTF-8) and for values that
#                           overflow the nanosecond conversion.
#   3. percent_encode     — output is always printable ASCII, so a hostile
#                           message can never smuggle CR, LF or NUL into a
#                           trailer.
#   4. response metadata  — nothing reserved, pseudo-prefixed, or containing a
#                           forbidden byte ever reaches the wire.
#
# Iteration count is `GRPCSERVER_FUZZ_ITERATIONS` (default 20_000 — a few
# seconds, suitable for every CI run). Raise it for a campaign:
#
#     GRPCSERVER_FUZZ_ITERATIONS=1000000 julia --project=. test/fuzz/fuzz_receive_path.jl
#
# The seed is fixed so a failing run is reproducible. Anything this finds must
# become a deterministic regression test in test/security/ — the fuzzer proves a
# bug exists, the regression test keeps it fixed.

using Test
using Random
using Logging
using gRPCServer
using gRPCServer: FrameReader, read_message!, GRPCError, CompressionCodec,
                  compress, parse_grpc_timeout, percent_encode,
                  ServerContext, set_header!, get_response_headers,
                  _RESERVED_RESPONSE_KEYS

const FUZZ_N = parse(Int, get(ENV, "GRPCSERVER_FUZZ_ITERATIONS", "20000"))
const FUZZ_SEED = parse(UInt64, get(ENV, "GRPCSERVER_FUZZ_SEED", "20260818"))
const FUZZ_CAP = 64 * 1024

_header(flag::UInt8, declared::Integer) =
    vcat(UInt8[flag], reinterpret(UInt8, [hton(UInt32(declared))]))

# A frame whose declared length is deliberately allowed to disagree with the
# payload it carries — that disagreement is most of the attack surface.
function _frame(rng)
    flag = rand(rng, UInt8[0x00, 0x01, rand(rng, UInt8)])
    payload = rand(rng, UInt8, rand(rng, 0:200))
    declared = rand(rng, UInt32[
        UInt32(length(payload)),        # honest
        UInt32(rand(rng, 0:500)),       # mismatched
        typemax(UInt32),                # ceiling
        typemax(UInt32) - UInt32(rand(rng, 0:3)),
        UInt32(FUZZ_CAP), UInt32(FUZZ_CAP + 1),   # cap boundary
    ])
    return vcat(_header(flag, declared), payload)
end

function _compressed_frame(rng)
    raw = rand(rng, UInt8, rand(rng, 0:2000))
    codec = rand(rng, [CompressionCodec.GZIP, CompressionCodec.DEFLATE])
    c = compress(raw, codec)
    # Truncate sometimes, so corrupt streams are covered too.
    rand(rng) < 0.3 && (c = c[1:max(0, length(c) - rand(rng, 1:5))])
    return vcat(_header(0x01, length(c)), c)
end

function _gen(rng)
    k = rand(rng, 1:4)
    k == 1 && return rand(rng, UInt8, rand(rng, 0:64))       # pure noise
    k == 2 && return _frame(rng)
    k == 3 && return vcat((_frame(rng) for _ in 1:rand(rng, 1:4))...)
    return _compressed_frame(rng)
end

# Drain a reader the way the dispatch layer does.
function _drive(bytes::Vector{UInt8}, encoding)
    fr = FrameReader(IOBuffer(bytes), FUZZ_CAP, encoding)
    n = 0
    while true
        m = read_message!(fr)
        m === nothing && break
        read(m)
        n += 1
        # A well-formed stream of this size cannot yield this many messages;
        # hitting it means the reader failed to advance.
        n > 10_000 && error("FrameReader did not make progress")
    end
    return n
end

@testset "Fuzz: peer-controlled receive path ($(FUZZ_N) iterations)" begin
    rng = Random.Xoshiro(FUZZ_SEED)

    @testset "FrameReader: only GRPCError escapes" begin
        offenders = Tuple{Vector{UInt8}, Any, Any}[]
        for _ in 1:FUZZ_N
            encoding = rand(rng, [nothing, "gzip", "deflate", "identity", "br"])
            bytes = _gen(rng)
            try
                _drive(bytes, encoding)
            catch e
                e isa GRPCError && continue
                push!(offenders, (bytes, encoding, e))
                length(offenders) >= 5 && break
            end
        end
        if !isempty(offenders)
            bytes, encoding, e = offenders[1]
            @info "Fuzz counterexample" encoding bytes = bytes2hex(bytes) exception = e
        end
        @test isempty(offenders)
    end

    @testset "FrameReader: allocation follows bytes received, not declared" begin
        # The security property behind the length-prefix check. A peer that
        # declares a huge message and then sends (almost) nothing must not make
        # the server allocate the declared size.
        big = 64 * 1024 * 1024
        function peak_buffer(bytes)
            fr = FrameReader(IOBuffer(bytes), big)
            try
                read_message!(fr)
            catch e
                e isa GRPCError || rethrow()
            end
            return length(fr.buf)
        end

        @test peak_buffer(_header(0x00, big)) <= 1024 * 1024
        @test peak_buffer(vcat(_header(0x00, big), rand(UInt8, 1024))) <= 1024 * 1024
        @test peak_buffer(vcat(_header(0x00, big), rand(UInt8, 64 * 1024))) <= 4 * 1024 * 1024
    end

    @testset "parse_grpc_timeout: only GRPCError escapes" begin
        offenders = Tuple{String, Any}[]
        for _ in 1:FUZZ_N
            s = if rand(rng) < 0.5
                String(rand(rng, UInt8, rand(rng, 0:12)))    # arbitrary octets
            else
                # Shapes near the grammar, including the overflow case (99999999H
                # exceeds Int64 nanoseconds).
                string(rand(rng, 0:99_999_999), rand(rng, "HMSmun XZ"))
            end
            try
                parse_grpc_timeout(s)
            catch e
                e isa GRPCError && continue
                push!(offenders, (s, e))
                length(offenders) >= 5 && break
            end
        end
        isempty(offenders) || @info "Fuzz counterexample" input = repr(offenders[1][1]) exception = offenders[1][2]
        @test isempty(offenders)
    end

    @testset "percent_encode: output is always printable ASCII" begin
        offenders = Tuple{String, Any}[]
        for _ in 1:FUZZ_N
            s = String(rand(rng, UInt8, rand(rng, 0:40)))
            out = try
                percent_encode(s)
            catch e
                push!(offenders, (s, e))
                length(offenders) >= 5 && break
                continue
            end
            if !all(c -> isascii(c) && ' ' <= c <= '~', out)
                push!(offenders, (s, out))
                length(offenders) >= 5 && break
            end
        end
        isempty(offenders) || @info "Fuzz counterexample" input = repr(offenders[1][1]) output = repr(offenders[1][2])
        @test isempty(offenders)
    end

    @testset "Response metadata: nothing forbidden reaches the wire" begin
        offenders = Tuple{String, String}[]
        # The validator warns on every rejection; that is the point, but it would
        # drown the run.
        with_logger(NullLogger()) do
            for _ in 1:FUZZ_N
                key = String(rand(rng, UInt8, rand(rng, 0:12)))
                value = String(rand(rng, UInt8, rand(rng, 0:12)))
                ctx = ServerContext()
                try
                    set_header!(ctx, key, value)
                catch
                    continue    # lowercase() can reject invalid UTF-8 upstream
                end
                for (k, v) in get_response_headers(ctx)
                    if startswith(k, ":") || k in _RESERVED_RESPONSE_KEYS ||
                       any(c -> c == '\r' || c == '\n' || c == '\0', v)
                        push!(offenders, (k, v))
                    end
                end
                length(offenders) >= 5 && break
            end
        end
        isempty(offenders) || @info "Fuzz counterexample" key = repr(offenders[1][1]) value = repr(offenders[1][2])
        @test isempty(offenders)
    end
end
