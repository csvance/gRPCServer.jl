module gRPCServer

using PrecompileTools: @setup_workload, @compile_workload

using HTTP
using ProtoBuf
using Base.Threads
import Reseau
import ProtoBuf.CodeGenerators

"""
    gRPCException <: Exception

Abstract supertype for the errors raised by gRPCServer. The concrete type a
handler throws to control the response is [`gRPCServiceCallException`](@ref).
"""
abstract type gRPCException <: Exception end

"""
    gRPCServiceCallException(grpc_status::Int, message::String) <: gRPCException

Exception type that is thrown (or returned to the client as a non-OK trailer)
when something goes wrong while handling an RPC.

This exception type has two fields:

1. `grpc_status::Int` - See [here](https://grpc.io/docs/guides/status-codes/) for an in-depth explanation of each status.
2. `message::String`

A handler can `throw` this to control the `grpc-status` and `grpc-message`
trailers sent back to the caller.
"""
struct gRPCServiceCallException <: gRPCException
    grpc_status::Int
    message::String
end

const GRPC_HEADER_SIZE = 5

"""
    GRPC_OK = 0

gRPC status code `OK`: not an error, returned on success. The canonical gRPC
status codes are exported as `GRPC_*` integer constants and listed in
[`GRPC_CODE_TABLE`](@ref). Pass one to [`gRPCServiceCallException`](@ref) to set
the `grpc-status` trailer. See the
[gRPC status code reference](https://grpc.io/docs/guides/status-codes/) for the
full semantics of each.
"""
const GRPC_OK = 0

"gRPC status code `CANCELLED` (1): the operation was cancelled, typically by the caller."
const GRPC_CANCELLED = 1

"gRPC status code `UNKNOWN` (2): an unknown error, for example an exception with no mapped status."
const GRPC_UNKNOWN = 2

"gRPC status code `INVALID_ARGUMENT` (3): the client supplied an argument that is invalid regardless of system state."
const GRPC_INVALID_ARGUMENT = 3

"gRPC status code `DEADLINE_EXCEEDED` (4): the deadline expired before the operation could complete."
const GRPC_DEADLINE_EXCEEDED = 4

"gRPC status code `NOT_FOUND` (5): a requested entity was not found."
const GRPC_NOT_FOUND = 5

"gRPC status code `ALREADY_EXISTS` (6): the entity a client attempted to create already exists."
const GRPC_ALREADY_EXISTS = 6

"gRPC status code `PERMISSION_DENIED` (7): the caller is authenticated but not authorized for the operation."
const GRPC_PERMISSION_DENIED = 7

"gRPC status code `RESOURCE_EXHAUSTED` (8): a resource is exhausted, for example a quota or the server concurrency cap."
const GRPC_RESOURCE_EXHAUSTED = 8

"gRPC status code `FAILED_PRECONDITION` (9): the system is not in the state required for the operation."
const GRPC_FAILED_PRECONDITION = 9

"gRPC status code `ABORTED` (10): the operation was aborted, often due to a concurrency conflict."
const GRPC_ABORTED = 10

"gRPC status code `OUT_OF_RANGE` (11): the operation was attempted past the valid range."
const GRPC_OUT_OF_RANGE = 11

"gRPC status code `UNIMPLEMENTED` (12): the operation is not implemented or not supported."
const GRPC_UNIMPLEMENTED = 12

"gRPC status code `INTERNAL` (13): an internal error; also the default mapping for an unhandled handler exception."
const GRPC_INTERNAL = 13

"gRPC status code `UNAVAILABLE` (14): the service is currently unavailable, usually a transient condition."
const GRPC_UNAVAILABLE = 14

"gRPC status code `DATA_LOSS` (15): unrecoverable data loss or corruption."
const GRPC_DATA_LOSS = 15

"gRPC status code `UNAUTHENTICATED` (16): the request lacks valid authentication credentials."
const GRPC_UNAUTHENTICATED = 16

"""
    GRPC_CODE_TABLE::Dict{Int64,String}

Maps each gRPC status code to its canonical name (for example `3 => "INVALID_ARGUMENT"`).
Used when formatting a [`gRPCServiceCallException`](@ref) for display.
"""
const GRPC_CODE_TABLE = Dict{Int64,String}(
    0 => "OK",
    1 => "CANCELLED",
    2 => "UNKNOWN",
    3 => "INVALID_ARGUMENT",
    4 => "DEADLINE_EXCEEDED",
    5 => "NOT_FOUND",
    6 => "ALREADY_EXISTS",
    7 => "PERMISSION_DENIED",
    8 => "RESOURCE_EXHAUSTED",
    9 => "FAILED_PRECONDITION",
    10 => "ABORTED",
    11 => "OUT_OF_RANGE",
    12 => "UNIMPLEMENTED",
    13 => "INTERNAL",
    14 => "UNAVAILABLE",
    15 => "DATA_LOSS",
    16 => "UNAUTHENTICATED",
)

function Base.showerror(io::IO, e::gRPCServiceCallException)
    print(
        io,
        "gRPCServiceCallException(grpc_status=$(GRPC_CODE_TABLE[e.grpc_status])($(e.grpc_status)), message=\"$(e.message)\")",
    )
end

include("Utils.jl")
include("gRPC.jl")
include("Server.jl")
include("Unary.jl")
include("Streaming.jl")
include("ProtoBuf.jl")

export gRPCMethod, gRPCRouter, gRPCContext
export handle!, serve, serve!
export metadata, set_initial_metadata!, set_trailing_metadata!
export deadline_exceeded, iscancelled
export grpc_register_service_codegen

export gRPCException, gRPCServiceCallException

export GRPC_OK,
    GRPC_CANCELLED,
    GRPC_UNKNOWN,
    GRPC_INVALID_ARGUMENT,
    GRPC_DEADLINE_EXCEEDED,
    GRPC_NOT_FOUND,
    GRPC_ALREADY_EXISTS,
    GRPC_PERMISSION_DENIED,
    GRPC_RESOURCE_EXHAUSTED,
    GRPC_FAILED_PRECONDITION,
    GRPC_ABORTED,
    GRPC_OUT_OF_RANGE,
    GRPC_UNIMPLEMENTED,
    GRPC_INTERNAL,
    GRPC_UNAVAILABLE,
    GRPC_DATA_LOSS,
    GRPC_UNAUTHENTICATED
export GRPC_CODE_TABLE

function __init__()
    grpc_register_service_codegen()
end

@setup_workload begin
    @compile_workload begin
        # Exercise descriptor construction and handler registration (no socket).
        router = gRPCRouter()
        m = gRPCMethod{Vector{UInt8},false,Vector{UInt8},false}("/pkg.Svc/M")
        handle!(router, m, (req, ctx) -> req)
    end
end

end # module gRPCServer
