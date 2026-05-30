# Core types: method descriptors, the router, the per-request context, and the
# gRPC length-prefixed message framing.

"""
    gRPCMethod{TRequest, RequestStream, TResponse, ResponseStream}(path)

Describes a single RPC method. Mirrors the client's
`gRPCServiceClient{TReq,ReqStream,TResp,RespStream}`: the type parameters carry
the request/response message types and the two streaming flags, while `path` is
the gRPC path (`"/pkg.Service/Method"`). Code generation emits one of these per
RPC.
"""
struct gRPCMethod{TRequest,RequestStream,TResponse,ResponseStream}
    path::String
end

@inline req_type(::gRPCMethod{TReq}) where {TReq} = TReq
@inline resp_type(::gRPCMethod{TReq,RS,TResp}) where {TReq,RS,TResp} = TResp
@inline is_req_stream(::gRPCMethod{TReq,RS}) where {TReq,RS} = RS
@inline is_resp_stream(::gRPCMethod{TReq,RS,TResp,SS}) where {TReq,RS,TResp,SS} = SS

# A type-erased router entry. `dispatch` is a closure that captures the concrete
# `gRPCMethod` and user handler, so once it is invoked everything past the call
# is type-stable (the function-barrier pattern).
struct gRPCRouterEntry
    path::String
    dispatch::Function
end

"""
    gRPCRouter(; max_recieve_message_length=4MiB, max_send_message_length=4MiB)

Holds the path-to-handler routing table. Reusable and non-parametric: user
application state is attached at `serve` time via `context=`, not here.
"""
struct gRPCRouter
    routes::Dict{String,gRPCRouterEntry}
    max_recieve_message_length::Int64
    max_send_message_length::Int64
end

function gRPCRouter(;
    max_recieve_message_length = 4 * 1024 * 1024,
    max_send_message_length = 4 * 1024 * 1024,
)
    return gRPCRouter(
        Dict{String,gRPCRouterEntry}(),
        Int64(max_recieve_message_length),
        Int64(max_send_message_length),
    )
end

"""
    gRPCContext{T}

Passed as the final argument to every handler. `payload::T` holds the user
application state supplied via `serve(...; context=...)` (Oxygen-style). The
remaining fields expose request metadata, the parsed deadline, cancellation, and
settable response/trailing metadata.
"""
mutable struct gRPCContext{T}
    payload::T
    path::String
    headers::HTTP.Headers
    peer::String
    deadline_ns::Int64
    initial_metadata::Vector{Pair{String,String}}
    trailing_metadata::Vector{Pair{String,String}}
    initial_sent::Bool
    cancelled::Threads.Atomic{Bool}
    sticky::Bool
    stream::HTTP.Stream
end

function gRPCContext(
    payload::T,
    path::AbstractString,
    headers::HTTP.Headers,
    peer::AbstractString,
    deadline_ns::Integer,
    stream::HTTP.Stream,
) where {T}
    return gRPCContext{T}(
        payload,
        String(path),
        headers,
        String(peer),
        Int64(deadline_ns),
        Pair{String,String}[],
        Pair{String,String}[],
        false,
        Threads.Atomic{Bool}(false),
        false,
        stream,
    )
end

"""
    metadata(ctx, key, default="") -> String

Look up a request metadata value (HTTP request header) by `key`.
"""
metadata(ctx::gRPCContext, key::AbstractString, default = "") =
    HTTP.header(ctx.headers, key, default)

"""
    set_initial_metadata!(ctx, key, value)

Queue a response header (initial metadata) to be sent with the response head.
Throws if the response head has already been sent.
"""
function set_initial_metadata!(ctx::gRPCContext, key::AbstractString, value::AbstractString)
    ctx.initial_sent &&
        throw(ArgumentError("cannot set initial metadata after the response head was sent"))
    push!(ctx.initial_metadata, String(key) => String(value))
    return ctx
end

"""
    set_trailing_metadata!(ctx, key, value)

Queue a custom trailing-metadata header, emitted alongside `grpc-status` when
the response completes.
"""
function set_trailing_metadata!(
    ctx::gRPCContext,
    key::AbstractString,
    value::AbstractString,
)
    push!(ctx.trailing_metadata, String(key) => String(value))
    return ctx
end

"""
    deadline_exceeded(ctx) -> Bool

True when a `grpc-timeout` deadline was supplied and has now passed.
"""
deadline_exceeded(ctx::gRPCContext) =
    ctx.deadline_ns != 0 && Int64(time_ns()) >= ctx.deadline_ns

"""
    iscancelled(ctx) -> Bool

True once the peer has cancelled the stream / closed the connection, or the
deadline has passed.
"""
iscancelled(ctx::gRPCContext) = ctx.cancelled[] || deadline_exceeded(ctx)

# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

"""
    grpc_encode_message_iobuffer(message, [buf]; max_send_message_length=4MiB) -> IOBuffer

Encode `message` into the 5-byte gRPC length-prefixed framing (1 compression
byte set to 0, then a big-endian `UInt32` length, then the ProtoBuf payload).
Mirrors the client's `grpc_encode_request_iobuffer`.
"""
function grpc_encode_message_iobuffer(
    message,
    buf::IOBuffer;
    max_send_message_length = 4 * 1024 * 1024,
)
    start_pos = position(buf)

    write(buf, UInt8(0))
    write(buf, UInt32(0))

    e = ProtoEncoder(buf)
    sz = UInt32(encode(e, message))

    end_pos = position(buf)

    if buf.size - GRPC_HEADER_SIZE > max_send_message_length
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "response message larger than max_send_message_length: $(buf.size - GRPC_HEADER_SIZE) > $max_send_message_length",
            ),
        )
    end

    seek(buf, start_pos + 1)
    write(buf, hton(sz))
    seek(buf, end_pos)

    return buf
end

grpc_encode_message_iobuffer(message; max_send_message_length = 4 * 1024 * 1024) =
    grpc_encode_message_iobuffer(
        message,
        IOBuffer();
        max_send_message_length = max_send_message_length,
    )

"""
    FrameReader(stream, max_recieve_message_length)

Pull-based decoder of the gRPC length-prefixed framing over an `HTTP.Stream`
request body. The server analog of the client's push-based `handle_write`.
"""
mutable struct FrameReader
    stream::HTTP.Stream
    max_recieve_message_length::Int64
    chunk::Vector{UInt8}
    carry::Vector{UInt8}
    off::Int
    eof::Bool
end

FrameReader(stream::HTTP.Stream, max_recieve_message_length::Integer) = FrameReader(
    stream,
    Int64(max_recieve_message_length),
    Vector{UInt8}(undef, 64 * 1024),
    UInt8[],
    0,
    false,
)

@inline _avail(fr::FrameReader) = length(fr.carry) - fr.off

# Ensure at least `n` unconsumed bytes are buffered, reading from the stream as
# needed. Returns true if `n` bytes are available, false at end-of-stream.
function _ensure!(fr::FrameReader, n::Int)
    while _avail(fr) < n && !fr.eof
        m = HTTP.readbytes!(fr.stream, fr.chunk, length(fr.chunk))
        if m == 0
            fr.eof = true
        else
            append!(fr.carry, view(fr.chunk, 1:m))
        end
    end
    return _avail(fr) >= n
end

"""
    read_message!(fr) -> Union{Nothing, IOBuffer}

Return the next fully-framed message as an `IOBuffer` positioned at the start,
or `nothing` at a clean half-close (end of the request stream). Throws
`gRPCServiceCallException` on a compressed frame, an oversize length prefix, or a
truncated frame.
"""
function read_message!(fr::FrameReader)::Union{Nothing,IOBuffer}
    # Drop already-consumed bytes so appends stay cheap.
    if fr.off > 0
        deleteat!(fr.carry, 1:fr.off)
        fr.off = 0
    end

    if !_ensure!(fr, GRPC_HEADER_SIZE)
        _avail(fr) == 0 && return nothing
        throw(gRPCServiceCallException(GRPC_INTERNAL, "stream ended mid-frame (header)"))
    end

    compressed = fr.carry[fr.off+1] > 0
    len =
        (UInt32(fr.carry[fr.off+2]) << 24) |
        (UInt32(fr.carry[fr.off+3]) << 16) |
        (UInt32(fr.carry[fr.off+4]) << 8) |
        UInt32(fr.carry[fr.off+5])
    fr.off += GRPC_HEADER_SIZE

    compressed && throw(
        gRPCServiceCallException(
            GRPC_UNIMPLEMENTED,
            "Request was compressed but compression is not currently supported.",
        ),
    )

    if len > fr.max_recieve_message_length
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "length-prefix longer than max_recieve_message_length: $(len) > $(fr.max_recieve_message_length)",
            ),
        )
    end

    len == 0 && return IOBuffer(UInt8[])

    if !_ensure!(fr, Int(len))
        throw(gRPCServiceCallException(GRPC_INTERNAL, "stream ended mid-frame (payload)"))
    end

    payload = fr.carry[(fr.off+1):(fr.off+Int(len))]
    fr.off += Int(len)
    return IOBuffer(payload)
end

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

# Unary: fn(req::TReq, ctx) -> TResp
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,false,TResp,false},
    fn,
) where {TReq,TResp}
    disp = (stream, ctx) -> _invoke_unary(stream, ctx, m, fn, router)
    router.routes[m.path] = gRPCRouterEntry(m.path, disp)
    return router
end

# Server streaming: fn(req::TReq, out::Channel{TResp}, ctx)
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,false,TResp,true},
    fn,
) where {TReq,TResp}
    disp = (stream, ctx) -> _invoke_server_stream(stream, ctx, m, fn, router)
    router.routes[m.path] = gRPCRouterEntry(m.path, disp)
    return router
end

# Client streaming: fn(in::Channel{TReq}, ctx) -> TResp
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,true,TResp,false},
    fn,
) where {TReq,TResp}
    disp = (stream, ctx) -> _invoke_client_stream(stream, ctx, m, fn, router)
    router.routes[m.path] = gRPCRouterEntry(m.path, disp)
    return router
end

# Bidirectional streaming: fn(in::Channel{TReq}, out::Channel{TResp}, ctx)
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,true,TResp,true},
    fn,
) where {TReq,TResp}
    disp = (stream, ctx) -> _invoke_bidi(stream, ctx, m, fn, router)
    router.routes[m.path] = gRPCRouterEntry(m.path, disp)
    return router
end

# do-block form: handle!(router, method) do ... end
handle!(fn::Function, router::gRPCRouter, m::gRPCMethod) = handle!(router, m, fn)
