# Reusable TestService server implementation, matching gRPCClient.jl's test
# expectations. Echo semantics:
#   unary TestRPC(req):  data = 1:req.test_response_sz
#   server-stream:       emit req.test_response_sz messages, message i = 1:i
#   client-stream:       count n requests, return 1:n
#   bidi:                for the i-th request, emit 1:i
#
# Handlers are registered via inline gRPCMethod descriptors rather than the
# generated register_TestService!, so this file is portable to a test harness
# whose generated stub is client-only (e.g. gRPCClient.jl's). It assumes the
# TestRequest / TestResponse types are already in scope.

const TESTSERVICE_TestRPC =
    gRPCServer.gRPCMethod{TestRequest,false,TestResponse,false}("/test.TestService/TestRPC")
const TESTSERVICE_TestServerStreamRPC =
    gRPCServer.gRPCMethod{TestRequest,false,TestResponse,true}(
        "/test.TestService/TestServerStreamRPC",
    )
const TESTSERVICE_TestClientStreamRPC =
    gRPCServer.gRPCMethod{TestRequest,true,TestResponse,false}(
        "/test.TestService/TestClientStreamRPC",
    )
const TESTSERVICE_TestBidirectionalStreamRPC =
    gRPCServer.gRPCMethod{TestRequest,true,TestResponse,true}(
        "/test.TestService/TestBidirectionalStreamRPC",
    )

function build_test_router(;
    max_recieve_message_length = 4 * 1024 * 1024,
    max_send_message_length = 4 * 1024 * 1024,
)
    router = gRPCServer.gRPCRouter(;
        max_recieve_message_length = max_recieve_message_length,
        max_send_message_length = max_send_message_length,
    )

    gRPCServer.handle!(router, TESTSERVICE_TestRPC) do req, ctx
        TestResponse(collect(UInt64, 1:req.test_response_sz))
    end

    gRPCServer.handle!(router, TESTSERVICE_TestServerStreamRPC) do req, out, ctx
        for i = 1:req.test_response_sz
            put!(out, TestResponse(collect(UInt64, 1:i)))
        end
    end

    gRPCServer.handle!(router, TESTSERVICE_TestClientStreamRPC) do in, ctx
        n = 0
        for _ in in
            n += 1
        end
        TestResponse(collect(UInt64, 1:n))
    end

    gRPCServer.handle!(router, TESTSERVICE_TestBidirectionalStreamRPC) do in, out, ctx
        i = 0
        for _ in in
            i += 1
            put!(out, TestResponse(collect(UInt64, 1:i)))
        end
    end

    return router
end

function start_test_server(host = "127.0.0.1", port = 0; context = nothing, kwargs...)
    return gRPCServer.serve!(build_test_router(), host, port; context = context, kwargs...)
end
