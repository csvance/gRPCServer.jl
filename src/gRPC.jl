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
    gRPCRouter(; max_receive_message_length=4MiB, max_send_message_length=4MiB)

Holds the path-to-handler routing table. Reusable and non-parametric: user
application state is attached at `serve` time via `context=`, not here.
"""
struct gRPCRouter
    routes::Dict{String,gRPCRouterEntry}
    max_receive_message_length::Int64
    max_send_message_length::Int64
end

function gRPCRouter(;
    max_receive_message_length = 4 * 1024 * 1024,
    max_send_message_length = 4 * 1024 * 1024,
)
    return gRPCRouter(
        Dict{String,gRPCRouterEntry}(),
        Int64(max_receive_message_length),
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
# Write the message body into `buf` and return the number of bytes written. The
# generic method ProtoBuf-encodes a typed message; the `AbstractVector{UInt8}`
# method writes an already-encoded protobuf payload verbatim, enabling raw /
# partial-decode responses (a method whose `TResponse` is `Vector{UInt8}`).
_encode_body(buf::IOBuffer, message) = UInt32(encode(ProtoEncoder(buf), message))
_encode_body(buf::IOBuffer, message::AbstractVector{UInt8}) = UInt32(write(buf, message))

# Turn a received message `IOBuffer` into the value handed to the handler. The
# generic method ProtoBuf-decodes into `T`; the `Vector{UInt8}` method returns a
# fresh copy of the raw protobuf payload, enabling raw / partial decoding. The
# copy matters: `read_message!` returns a buffer borrowing the FrameReader's
# internal storage, valid only until the next read.
_decode_message(io, ::Type{T}) where {T} = decode(ProtoDecoder(io), T)
_decode_message(io, ::Type{Vector{UInt8}}) = read(seekstart(io))

# Decode a request message, mapping a malformed wire-format payload to
# INVALID_ARGUMENT. A body that ProtoBuf.jl cannot parse is a client fault, not a
# server bug, so it should not surface as INTERNAL (which would also risk echoing
# ProtoBuf.jl internals back to the peer). A gRPCServiceCallException raised
# deeper (e.g. an oversize nested frame) is passed through unchanged.
function _decode_request(io, ::Type{T}) where {T}
    try
        return _decode_message(io, T)
    catch err
        err isa gRPCServiceCallException && rethrow()
        throw(
            gRPCServiceCallException(
                GRPC_INVALID_ARGUMENT,
                "failed to decode request message",
            ),
        )
    end
end

function grpc_encode_message_iobuffer(
    message,
    buf::IOBuffer;
    max_send_message_length = 4 * 1024 * 1024,
)
    start_pos = position(buf)

    write(buf, UInt8(0))
    write(buf, UInt32(0))

    sz = _encode_body(buf, message)

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

# Convenience method that allocates the framing buffer. `sizehint` (bytes,
# including the 5-byte header) pre-grows that buffer so a large message does not
# trigger repeated reallocation as it encodes; `0` keeps the default growth.
function grpc_encode_message_iobuffer(
    message;
    max_send_message_length = 4 * 1024 * 1024,
    sizehint::Integer = 0,
)
    buf = sizehint > 0 ? IOBuffer(; sizehint = Int(sizehint)) : IOBuffer()
    return grpc_encode_message_iobuffer(
        message,
        buf;
        max_send_message_length = max_send_message_length,
    )
end

# How many bytes to request from HTTP.jl per read. HTTP.jl's server-side
# `readbytes!` allocates a temporary of exactly this size per call, so it is
# capped rather than sized to the (possibly large) free tail of `buf`.
const _FRAME_READ_CHUNK = 64 * 1024

# `read_message!` returns an `IOBuffer` wrapping a view into the reader's buffer
# (zero-copy). That view-backed buffer is a distinct concrete type from the
# default `IOBuffer` alias (`GenericIOBuffer{Memory{UInt8}}`), so it is named
# here and used as the return type, keeping the function type-stable.
const _FrameView = SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}
const _FrameBuffer = Base.GenericIOBuffer{_FrameView}

"""
    FrameReader(stream, max_receive_message_length)

Pull-based decoder of the gRPC length-prefixed framing over an `HTTP.Stream`
request body. The server analog of the client's push-based `handle_write`.

A single growable `buf` holds the bytes pulled from the stream. `r` is the read
offset (bytes `1:r` have been consumed) and `w` is the write offset (bytes
`1:w` are valid). Stream bytes are read straight into the free tail of `buf`,
and `read_message!` returns a view into `buf` rather than a copy, so a received
message is not copied on its way to the decoder.
"""
# Parametric on the source `IO` so the framing logic can be driven from a plain
# `IOBuffer` in tests; in the server it is always an `HTTP.Stream`. `HTTP.readbytes!`
# is `Base.readbytes!`, so it dispatches correctly for either source.
mutable struct FrameReader{S<:IO}
    stream::S
    max_receive_message_length::Int64
    buf::Vector{UInt8}
    r::Int
    w::Int
    eof::Bool
end

FrameReader(stream::IO, max_receive_message_length::Integer) = FrameReader(
    stream,
    Int64(max_receive_message_length),
    Vector{UInt8}(undef, _FRAME_READ_CHUNK),
    0,
    0,
    false,
)

@inline _avail(fr::FrameReader) = fr.w - fr.r

# Make room to read more bytes while keeping `need` unconsumed bytes reachable.
# Compaction (shifting the unconsumed tail to the front) is done only when the
# consumed prefix has grown large or the buffer is full, rather than on every
# call, so streaming many frames does not pay an O(remaining) memmove per frame.
function _reserve!(fr::FrameReader, need::Int)
    remaining = fr.w - fr.r
    if fr.r > 0 && (fr.r >= remaining || length(fr.buf) == fr.w)
        remaining > 0 && copyto!(fr.buf, 1, fr.buf, fr.r + 1, remaining)
        fr.r = 0
        fr.w = remaining
    end
    # Ensure the buffer can hold `need` unconsumed bytes and has tail room to
    # read into. For a large message this grows `buf` to the message size once.
    target = max(fr.r + need, fr.w + _FRAME_READ_CHUNK)
    length(fr.buf) < target && resize!(fr.buf, target)
    return nothing
end

# Ensure at least `n` unconsumed bytes are buffered, reading from the stream as
# needed. Returns true if `n` bytes are available, false at end-of-stream.
function _ensure!(fr::FrameReader, n::Int)
    while (fr.w - fr.r) < n && !fr.eof
        _reserve!(fr, n)
        nb = min(length(fr.buf) - fr.w, _FRAME_READ_CHUNK)
        m = HTTP.readbytes!(fr.stream, view(fr.buf, (fr.w+1):(fr.w+nb)), nb)
        if m == 0
            fr.eof = true
        else
            fr.w += m
        end
    end
    return (fr.w - fr.r) >= n
end

"""
    read_message!(fr) -> Union{Nothing, IOBuffer}

Return the next fully-framed message as an `IOBuffer` positioned at the start,
or `nothing` at a clean half-close (end of the request stream). Throws
`gRPCServiceCallException` on a compressed frame, an oversize length prefix, or a
truncated frame.

The returned `IOBuffer` borrows the reader's internal storage. It is only valid
until the next `read_message!` call (which may grow, compact, or reallocate that
storage), so it must be fully decoded before reading the following message. All
callers in this package decode immediately, which preserves that invariant.
"""
function read_message!(fr::FrameReader)::Union{Nothing,_FrameBuffer}
    if !_ensure!(fr, GRPC_HEADER_SIZE)
        (fr.w - fr.r) == 0 && return nothing
        throw(gRPCServiceCallException(GRPC_INTERNAL, "stream ended mid-frame (header)"))
    end

    compressed = fr.buf[fr.r+1] > 0
    len = ntoh(reinterpret(UInt32, view(fr.buf, (fr.r+2):(fr.r+5)))[1])
    fr.r += GRPC_HEADER_SIZE

    compressed && throw(
        gRPCServiceCallException(
            GRPC_UNIMPLEMENTED,
            "Request was compressed but compression is not currently supported.",
        ),
    )

    if len > fr.max_receive_message_length
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "length-prefix longer than max_receive_message_length: $(len) > $(fr.max_receive_message_length)",
            ),
        )
    end

    # Empty message: return an empty view of the same concrete type so every
    # branch yields `_FrameBuffer`.
    len == 0 && return IOBuffer(view(fr.buf, (fr.r+1):fr.r))

    if !_ensure!(fr, Int(len))
        throw(gRPCServiceCallException(GRPC_INTERNAL, "stream ended mid-frame (payload)"))
    end

    payload = view(fr.buf, (fr.r+1):(fr.r+Int(len)))
    fr.r += Int(len)
    return IOBuffer(payload)
end

# For unary and server-streaming RPCs the client must send exactly one message
# and half-close. We read one more frame: a clean half-close (`nothing`) means
# the body is fully consumed, so HTTP.jl does not force the underlying
# connection closed (which would cancel other multiplexed streams under load).
# Any further message is a protocol violation, rejected here rather than drained
# in an unbounded loop, so a misbehaving peer cannot pin the handler task by
# streaming an endless run of frames into a single-message RPC.
function expect_half_close!(fr::FrameReader)
    read_message!(fr) === nothing || throw(
        gRPCServiceCallException(
            GRPC_INVALID_ARGUMENT,
            "expected exactly one request message for a non-streaming request",
        ),
    )
    return nothing
end

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

"""
    handle!(router::gRPCRouter, m::gRPCMethod, fn) -> router
    handle!(fn, router::gRPCRouter, m::gRPCMethod) -> router

Register the handler `fn` for the method described by `m` on `router`, returning
the router so calls can be chained. The streaming flags carried in the
[`gRPCMethod`](@ref) type select the expected handler signature; the dispatcher
captured here is type-stable because `m` is concrete.

The four forms are:

  - **Unary** (`req`, `resp`): `fn(req::TReq, ctx) -> resp::TResp`
  - **Server streaming** (`req`, stream `resp`): `fn(req::TReq, out::Channel{TResp}, ctx)`
  - **Client streaming** (stream `req`, `resp`): `fn(in::Channel{TReq}, ctx) -> resp::TResp`
  - **Bidirectional** (stream `req`, stream `resp`): `fn(in::Channel{TReq}, out::Channel{TResp}, ctx)`

`ctx` is the [`gRPCContext`](@ref) carrying request metadata, the deadline, and
the user `payload`. A handler may `throw` a [`gRPCServiceCallException`](@ref) to
set the response status; any other exception maps to `GRPC_INTERNAL`.

The second (do-block) form is equivalent and reads naturally for inline handlers:

```julia
handle!(router, MyService_GetThing_Method()) do req, ctx
    Thing(query(ctx.payload.db, req.id))
end
```

Registering against a generated `*_Method` descriptor (or via the generated
`register_<Service>!` helper) is the usual path; see the Code Generation guide.
"""
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
