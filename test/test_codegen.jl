@testset "Code Generation" begin
    mktempdir() do tmpdir
        @test isnothing(
            protojl("proto/test.proto", @__DIR__, tmpdir; always_use_modules = true),
        )
        generated = read(joinpath(tmpdir, "test", "test_pb.jl"), String)

        # Server import + delimiters.
        @test contains(generated, "import gRPCServer")
        @test contains(generated, "# gRPCServer.jl BEGIN")
        @test contains(generated, "# gRPCServer.jl END")

        # Per-RPC descriptor constants with correct streaming flags.
        @test contains(
            generated,
            "const TestService_TestRPC_Method = gRPCServer.gRPCMethod{TestRequest, false, TestResponse, false}(\"/test.TestService/TestRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{TestRequest, false, TestResponse, true}(\"/test.TestService/TestServerStreamRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{TestRequest, true, TestResponse, false}(\"/test.TestService/TestClientStreamRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{TestRequest, true, TestResponse, true}(\"/test.TestService/TestBidirectionalStreamRPC\")",
        )

        # Raw descriptor constants: both sides Vector{UInt8}, streaming flags preserved.
        @test contains(
            generated,
            "const TestService_TestRPC_RawMethod = gRPCServer.gRPCMethod{Vector{UInt8}, false, Vector{UInt8}, false}(\"/test.TestService/TestRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{Vector{UInt8}, true, Vector{UInt8}, true}(\"/test.TestService/TestBidirectionalStreamRPC\")",
        )
        @test contains(generated, "export TestService_TestRPC_RawMethod")

        # register_<Service>! sugar.
        @test contains(generated, "function register_TestService!(router;")
        @test contains(
            generated,
            "gRPCServer.handle!(router, TestService_TestRPC_Method, TestRPC)",
        )

        # Exports gated on namespace / always_use_modules.
        @test contains(generated, "export TestService_TestRPC_Method")
        @test contains(generated, "export register_TestService!")

        # Client block coexists in the same file.
        @test contains(generated, "import gRPCClient")
        @test contains(generated, "# gRPCClient.jl BEGIN")
        @test contains(generated, "TestService_TestRPC_Client(")
    end
end
