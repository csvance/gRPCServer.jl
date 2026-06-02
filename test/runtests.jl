using Test
using ProtoBuf
using HTTP
using gRPCServer
import gRPCClient
using Base.Threads

# Loading both gRPCServer and gRPCClient registers both ProtoBuf codegen
# handlers via their __init__ functions. gRPCServer is brought into scope with
# `using`; gRPCClient is referenced qualified, since both packages export the
# same wire-protocol names (status constants, gRPCServiceCallException) by
# design and unqualified use would be ambiguous.

# Generated protobuf messages + client stubs + server descriptors.
include("gen/test/test_pb.jl")

# Shared TestService server implementation (echo semantics matching gRPCClient).
include("testservice.jl")

@testset "gRPCServer.jl" begin
    include("test_codegen.jl")
    include("test_framing.jl")
    include("test_status.jl")
    include("test_unit.jl")
    include("test_integration.jl")
    include("test_errors.jl")
    include("test_raw.jl")
    if !haskey(ENV, "GRPC_SERVER_TEST_SKIP_LOAD")
        include("test_load.jl")
    end
end
