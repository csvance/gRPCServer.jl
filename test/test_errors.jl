# End-to-end error-path coverage: a handler exception maps to the right gRPC
# status and reaches the client without leaking internals. Driven over h2c with
# gRPCClient at small scale.
#
# Note on the concurrency cap (max_concurrent_requests): its admission/shed path
# is exercised by code review rather than an automated test here. A faithful test
# would hold one RPC open while issuing a second over the cap, but the bundled
# gRPCClient routes every call through a single shared libcurl handle, so a
# held-open request stalls any concurrent one until its client deadline rather
# than letting the server shed it promptly. That makes an in-process shedding
# test unreliable; it belongs in a harness with an independent client.

@testset "Handler exception mapping" begin
    # One unary route that branches on the request: a plain exception must surface
    # as INTERNAL with a generic message (no handler internals leaked), an explicit
    # gRPCServiceCallException must pass its status and message through verbatim,
    # and a normal value must still round-trip.
    router = gRPCServer.gRPCRouter()
    gRPCServer.handle!(router, TESTSERVICE_TestRPC) do req, ctx
        if req.test_response_sz == 1
            error("internal handler detail that must not leak")
        elseif req.test_response_sz == 2
            throw(gRPCServiceCallException(GRPC_NOT_FOUND, "thing missing"))
        end
        TestResponse(collect(UInt64, 1:req.test_response_sz))
    end
    server = gRPCServer.serve!(router, "127.0.0.1", 0)
    port = HTTP.port(server)
    sleep(0.3)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port)

        # Plain exception -> INTERNAL, generic message (the server logs the real
        # error; only "internal error" is sent to the peer).
        ex = try
            gRPCClient.grpc_sync_request(client, TestRequest(1, UInt64[]))
            nothing
        catch e
            e
        end
        @test ex isa gRPCClient.gRPCServiceCallException
        @test ex.grpc_status == GRPC_INTERNAL
        @test !occursin("internal handler detail", ex.message)

        # Explicit service exception -> status and message preserved.
        ex2 = try
            gRPCClient.grpc_sync_request(client, TestRequest(2, UInt64[]))
            nothing
        catch e
            e
        end
        @test ex2 isa gRPCClient.gRPCServiceCallException
        @test ex2.grpc_status == GRPC_NOT_FOUND
        @test occursin("thing missing", ex2.message)

        # Normal path still works on the same route.
        ok = gRPCClient.grpc_sync_request(client, TestRequest(4, UInt64[]))
        @test length(ok.data) == 4
    finally
        close(server)
    end
end
