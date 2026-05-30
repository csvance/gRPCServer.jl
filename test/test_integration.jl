# End-to-end correctness pass: stand up the shared TestService server over h2c
# and drive every RPC pattern with gRPCClient.jl at small N. The heavy load
# sweep lives in test_load.jl.

@testset "Integration (h2c) server <-> gRPCClient" begin
    server = start_test_server("127.0.0.1", 0)
    port = HTTP.port(server)
    sleep(0.3)  # let the listener come up

    try
        @testset "unary" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            for i = 1:25
                resp = gRPCClient.grpc_sync_request(client, TestRequest(i, UInt64[]))
                @test length(resp.data) == i
                @test all(resp.data .== 1:i)
            end
        end

        @testset "unknown method -> UNIMPLEMENTED" begin
            bogus = gRPCClient.gRPCServiceClient{TestRequest,false,TestResponse,false}(
                "127.0.0.1",
                port,
                "/test.TestService/DoesNotExist",
            )
            try
                gRPCClient.grpc_sync_request(bogus, TestRequest(1, UInt64[]))
                @test false
            catch ex
                @test isa(ex, gRPCClient.gRPCServiceCallException)
                @test ex.grpc_status == GRPC_UNIMPLEMENTED
            end
        end

        @static if VERSION >= v"1.12"
            @testset "server streaming" begin
                N = 50
                client = TestService_TestServerStreamRPC_Client("127.0.0.1", port)
                response_c = Channel{TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, TestRequest(N, UInt64[]), response_c)
                for i = 1:N
                    resp = take!(response_c)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                gRPCClient.grpc_async_await(req)
            end

            @testset "client streaming" begin
                N = 50
                client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestRequest}(N)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:N
                    put!(request_c, TestRequest(1, UInt64[]))
                end
                close(request_c)
                resp = gRPCClient.grpc_async_await(client, req)
                @test length(resp.data) == N
                @test all(resp.data .== 1:N)
            end

            @testset "bidirectional streaming" begin
                N = 50
                client =
                    TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestRequest}(N)
                response_c = Channel{TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, request_c, response_c)
                for i = 1:N
                    put!(request_c, TestRequest(i, UInt64[]))
                end
                for i = 1:N
                    resp = take!(response_c)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                close(request_c)
                gRPCClient.grpc_async_await(req)
            end
        end
    finally
        close(server)
    end
end

# The context payload (Oxygen-style ctx.payload::T) threads through to handlers.
struct CtxProbe
    bump::UInt64
end

@testset "Context payload threads through" begin
    router = gRPCServer.gRPCRouter()
    gRPCServer.handle!(router, TESTSERVICE_TestRPC) do req, ctx
        @test ctx.payload isa CtxProbe
        TestResponse(collect(UInt64, 1:(req.test_response_sz + ctx.payload.bump)))
    end
    server = gRPCServer.serve!(router, "127.0.0.1", 0; context = CtxProbe(3))
    port = HTTP.port(server)
    sleep(0.3)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port)
        resp = gRPCClient.grpc_sync_request(client, TestRequest(2, UInt64[]))
        @test length(resp.data) == 5  # 2 + bump(3)
    finally
        close(server)
    end
end
