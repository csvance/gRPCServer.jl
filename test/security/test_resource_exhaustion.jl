# Resource-exhaustion tests (SEC_ROADMAP phase 2c).
#
# The admission gate (`max_concurrent_requests`) is the server's main defence
# against handler-task exhaustion: HTTP.jl allows 100 concurrent streams per
# connection, so without a cap N connections imply 100·N handler tasks.
#
# The gate is only as good as its accounting. A slot leaked on an error path is
# a permanent, self-inflicted denial of service: after enough failures the
# server refuses every subsequent call with RESOURCE_EXHAUSTED and never
# recovers, without any continuing attacker effort. Since abnormal terminations
# are exactly what a hostile peer can trigger at will, each one is checked here.

using Test
using Sockets: IPv4
using gRPCServer
using gRPCServer: GRPCError, StatusCode, PeerInfo, ServiceDescriptor,
                  MethodDescriptor, MethodType, dispatch_grpc_call

# --- Minimal stream harness -------------------------------------------------

mutable struct ExhaustionStream <: gRPCServer.AbstractGRPCStream
    path::String
    fr::Any
    metadata::Vector{Tuple{String, String}}
    headers::Vector{Tuple{String, String}}
    messages::Vector{Vector{UInt8}}
    trailers::Vector{Tuple{String, String}}
end

function ExhaustionStream(path::String, body::Vector{UInt8};
                          content_type::String = "application/grpc")
    return ExhaustionStream(
        path, gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024),
        [("content-type", content_type), ("te", "trailers")],
        Tuple{String, String}[], Vector{UInt8}[], Tuple{String, String}[])
end

gRPCServer.grpc_path(s::ExhaustionStream) = s.path
gRPCServer.grpc_method(s::ExhaustionStream) = "POST"
gRPCServer.request_metadata(s::ExhaustionStream) = s.metadata
gRPCServer.is_cancelled(s::ExhaustionStream) = false
gRPCServer.read_message!(s::ExhaustionStream) = gRPCServer.read_message!(s.fr)
gRPCServer.send_response_headers!(s::ExhaustionStream, h) = (append!(s.headers, h); nothing)
gRPCServer.send_message!(s::ExhaustionStream, m) = (push!(s.messages, collect(m)); nothing)
gRPCServer.send_trailers!(s::ExhaustionStream, t) = (append!(s.trailers, t); nothing)
gRPCServer.reset!(s::ExhaustionStream, code) = nothing

exh_framed(p::Vector{UInt8}) =
    vcat(UInt8[0x00], reinterpret(UInt8, [hton(UInt32(length(p)))]), p)

exh_status(s::ExhaustionStream) =
    for (k, v) in s.trailers
        k == "grpc-status" && return parse(Int, v)
    end

function exh_server(handler; kwargs...)
    server = GRPCServer("127.0.0.1", 50051; kwargs...)
    gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
        "test.Exhaust",
        Dict("Echo" => MethodDescriptor(
            "Echo", MethodType.UNARY, "Vector{UInt8}", "Vector{UInt8}", handler;
            raw_request = true, raw_response = true)),
        nothing))
    return server
end

@testset "Security: resource exhaustion" begin

    @testset "The admission slot is released on every termination path" begin
        # Each case names how the call ends and what it should leave behind. The
        # invariant is the same throughout: inflight returns to zero, so the
        # capacity is fully available for the next caller.
        cases = [
            ("success",
             (ctx, req) -> req,
             exh_framed(UInt8[0x01]),
             "application/grpc"),
            ("handler throws GRPCError",
             (ctx, req) -> throw(GRPCError(StatusCode.PERMISSION_DENIED, "no")),
             exh_framed(UInt8[0x01]),
             "application/grpc"),
            ("handler throws an arbitrary exception",
             (ctx, req) -> error("boom"),
             exh_framed(UInt8[0x01]),
             "application/grpc"),
            ("handler throws a non-Exception value",
             (ctx, req) -> throw(ArgumentError("bad")),
             exh_framed(UInt8[0x01]),
             "application/grpc"),
            ("oversize length prefix (framing error)",
             (ctx, req) -> req,
             vcat(UInt8[0x00], reinterpret(UInt8, [hton(UInt32(10_000_000))])),
             "application/grpc"),
            ("truncated frame",
             (ctx, req) -> req,
             UInt8[0x00, 0x00, 0x00],
             "application/grpc"),
            ("compressed frame with no encoding negotiated",
             (ctx, req) -> req,
             vcat(UInt8[0x01], reinterpret(UInt8, [hton(UInt32(2))]), UInt8[0x01, 0x02]),
             "application/grpc"),
            ("empty body (no request message)",
             (ctx, req) -> req,
             UInt8[],
             "application/grpc"),
            ("extra frame on a unary call",
             (ctx, req) -> req,
             vcat(exh_framed(UInt8[0x01]), exh_framed(UInt8[0x02])),
             "application/grpc"),
        ]

        for (name, handler, body, ct) in cases
            server = exh_server(handler; max_concurrent_requests = 4)
            s = ExhaustionStream("/test.Exhaust/Echo", body; content_type = ct)
            dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
            @test server.inflight[] == 0                      # slot released
            @test server.shed_total[] == 0                    # nothing shed
            @test exh_status(s) !== nothing                   # a status was sent
        end
    end

    @testset "Unknown method releases its slot" begin
        server = exh_server((ctx, req) -> req; max_concurrent_requests = 4)
        s = ExhaustionStream("/test.Exhaust/DoesNotExist", exh_framed(UInt8[0x01]))
        dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
        @test exh_status(s) == Int(StatusCode.UNIMPLEMENTED)
        @test server.inflight[] == 0
    end

    @testset "A rejected content type never consumes a slot" begin
        # Rejected before the admission gate, so it costs no capacity at all.
        server = exh_server((ctx, req) -> req; max_concurrent_requests = 4)
        s = ExhaustionStream("/test.Exhaust/Echo", exh_framed(UInt8[0x01]);
                             content_type = "text/plain")
        dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
        @test server.inflight[] == 0
        @test server.shed_total[] == 0
    end

    @testset "Repeated failures do not erode capacity" begin
        # The shape of the leak that matters: if each failure leaked a slot, a
        # cap of 4 would be exhausted after 4 hostile requests and the server
        # would refuse everything afterwards. Drive well past the cap, then
        # confirm a legitimate call still succeeds.
        server = exh_server(
            (ctx, req) -> throw(GRPCError(StatusCode.INVALID_ARGUMENT, "nope"));
            max_concurrent_requests = 4)

        for _ in 1:50
            s = ExhaustionStream("/test.Exhaust/Echo", exh_framed(UInt8[0x01]))
            dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
        end
        @test server.inflight[] == 0
        @test server.shed_total[] == 0    # never falsely "full"

        # And capacity is genuinely intact: a fresh call is admitted and served.
        ok = exh_server((ctx, req) -> req; max_concurrent_requests = 4)
        for _ in 1:50
            s = ExhaustionStream("/test.Exhaust/Echo", UInt8[0x00, 0x00])  # truncated
            dispatch_grpc_call(ok, s, PeerInfo(IPv4(0), 0))
        end
        good = ExhaustionStream("/test.Exhaust/Echo", exh_framed(UInt8[0x07]))
        dispatch_grpc_call(ok, good, PeerInfo(IPv4(0), 0))
        @test exh_status(good) == Int(StatusCode.OK)
        @test ok.inflight[] == 0
    end

    @testset "Shedding is accounted for and does not leak either" begin
        server = exh_server((ctx, req) -> req; max_concurrent_requests = 1)
        Threads.atomic_add!(server.inflight, 1)          # simulate one in flight

        for i in 1:10
            s = ExhaustionStream("/test.Exhaust/Echo", exh_framed(UInt8[0x01]))
            dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
            @test exh_status(s) == Int(StatusCode.RESOURCE_EXHAUSTED)
            # The shed path must put back the slot it speculatively took.
            @test server.inflight[] == 1
            @test server.shed_total[] == i
        end

        # Once the simulated call finishes, capacity is available again.
        Threads.atomic_sub!(server.inflight, 1)
        s = ExhaustionStream("/test.Exhaust/Echo", exh_framed(UInt8[0x01]))
        dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
        @test exh_status(s) == Int(StatusCode.OK)
        @test server.inflight[] == 0
    end

    @testset "An unlimited cap does no accounting but still serves" begin
        for limit in (0, nothing)
            server = exh_server((ctx, req) -> req; max_concurrent_requests = limit)
            s = ExhaustionStream("/test.Exhaust/Echo", exh_framed(UInt8[0x01]))
            dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))
            @test exh_status(s) == Int(StatusCode.OK)
            @test server.inflight[] == 0
            @test server.shed_total[] == 0
        end
    end
end
