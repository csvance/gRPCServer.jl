@testset "Status codes" begin
    # The status table covers 0..16.
    @test length(gRPCServer.GRPC_CODE_TABLE) == 17
    for code = 0:16
        @test haskey(gRPCServer.GRPC_CODE_TABLE, code)
    end
    @test gRPCServer.GRPC_CODE_TABLE[gRPCServer.GRPC_OK] == "OK"
    @test gRPCServer.GRPC_CODE_TABLE[gRPCServer.GRPC_UNIMPLEMENTED] == "UNIMPLEMENTED"
    @test gRPCServer.GRPC_CODE_TABLE[gRPCServer.GRPC_DEADLINE_EXCEEDED] == "DEADLINE_EXCEEDED"

    # showerror renders the status name and message.
    ex = gRPCServiceCallException(gRPCServer.GRPC_NOT_FOUND, "nope")
    s = sprint(showerror, ex)
    @test contains(s, "NOT_FOUND")
    @test contains(s, "nope")
end

@testset "grpc-timeout parsing" begin
    using gRPCServer: parse_grpc_timeout

    @test parse_grpc_timeout("") == 0
    # A 10-second timeout lands roughly 10s in the future.
    now = Int64(time_ns())
    d = parse_grpc_timeout("10S")
    @test d > now
    @test d - now <= 11_000_000_000
    @test_throws gRPCServiceCallException parse_grpc_timeout("10X")
end

@testset "Content-type acceptance" begin
    using gRPCServer: _is_grpc_content_type
    @test _is_grpc_content_type("application/grpc")
    @test _is_grpc_content_type("application/grpc+proto")
    @test _is_grpc_content_type("application/grpc;charset=utf-8")
    @test !_is_grpc_content_type("application/json")
    @test !_is_grpc_content_type("text/plain")
end
