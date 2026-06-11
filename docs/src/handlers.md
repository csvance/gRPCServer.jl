# Handlers

A handler is a function you register on a [`gRPCRouter`](@ref) for a given
method. Register handlers either through the generated `register_<Service>!`
helper, or individually with [`handle!`](@ref) against a `*_Method` descriptor.
Every handler receives a [`gRPCContext`](@ref) as its last argument.

## The four RPC patterns

The streaming flags carried in the [`gRPCMethod`](@ref) type select which
signature [`handle!`](@ref) expects:

| RPC type | Handler signature |
|----------|-------------------|
| Unary | `fn(req, ctx) -> resp` |
| Server streaming | `fn(req, out::Channel, ctx)` |
| Client streaming | `fn(in::Channel, ctx) -> resp` |
| Bidirectional | `fn(in::Channel, out::Channel, ctx)` |

For streaming RPCs, you consume requests by iterating the input `Channel` and
emit responses with `put!(out, msg)`. Closing of the channels and the gRPC
framing are handled by the library.

A streaming handler does not have to drain its input channel: returning (or
throwing) before the client half-closes is a legal completion. The library then
sends the trailers and abandons the rest of the request stream. Conversely, a
`put!` on the output channel can throw if the response stream has already
failed, for example after the peer reset the stream or a response exceeded
`max_send_message_length`; the thrown exception carries the original failure
and is mapped to the RPC status, so a handler normally just lets it propagate.

```julia
router = gRPCRouter()

# unary
handle!(router, MyService_GetThing_Method()) do req, ctx
    Thing(query(ctx.payload.db, req.id))
end

# bidirectional
handle!(router, MyService_Chat_Method()) do in, out, ctx
    for m in in
        put!(out, reply(m))
    end
end
```

## Raw request and response buffers

Override `TRequest` and/or `TResponse` with `Vector{UInt8}` to have the handler
receive the raw, undecoded protobuf payload and/or return raw response bytes
instead of a typed message. This lets a handler partially decode only the fields
it needs, or forward bytes it already holds. The raw buffer is the protobuf
message body only; the gRPC framing is still handled by the library.

```julia
# Both sides raw
handle!(router, MyService_GetThing_Method(; TRequest = Vector{UInt8}, TResponse = Vector{UInt8})) do req, ctx
    # req::Vector{UInt8}; return a Vector{UInt8}
end

# Mixed: typed request, raw response
handle!(router, MyService_GetThing_Method(; TResponse = Vector{UInt8})) do req, ctx
    # req::MyRequest; return a Vector{UInt8}
end
```

## Error handling

To control the response status, `throw` a
[`gRPCServiceCallException`](@ref)`(status, message)`; it is surfaced to the
caller as the `grpc-status` and `grpc-message` trailers. Any other exception
becomes `GRPC_INTERNAL`. The status codes are exported as `GRPC_*` constants
(see the [API Reference](api.md#Status-codes)).

```julia
handle!(router, MyService_GetThing_Method()) do req, ctx
    thing = query(ctx.payload.db, req.id)
    thing === nothing && throw(gRPCServiceCallException(GRPC_NOT_FOUND, "no such thing"))
    thing
end
```

## The context API

The [`gRPCContext`](@ref) passed to every handler carries the user `payload`,
request metadata, and the deadline.

- [`metadata`](@ref)`(ctx, key, default="")`: read a request metadata header
- [`set_initial_metadata!`](@ref)`(ctx, key, value)`: queue a response header.
  Works in all four RPC shapes; in a streaming handler, call it before the
  first `put!` on the output channel, since the response head goes out with the
  first message
- [`set_trailing_metadata!`](@ref)`(ctx, key, value)`: queue a trailing-metadata header
- [`deadline_exceeded`](@ref)`(ctx)` / [`iscancelled`](@ref)`(ctx)`: cooperative
  deadline and cancellation checks (see [Concurrency](concurrency.md#Deadlines-and-cancellation))

```julia
handle!(router, MyService_GetThing_Method()) do req, ctx
    token = metadata(ctx, "authorization")
    isempty(token) && throw(gRPCServiceCallException(GRPC_UNAUTHENTICATED, "missing token"))
    set_trailing_metadata!(ctx, "x-served-by", gethostname())
    Thing(query(ctx.payload.db, req.id))
end
```
