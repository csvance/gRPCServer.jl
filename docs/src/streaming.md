# Streaming

!!! danger "Streaming is unstable in v0.1 and not part of the supported API"
    Only **unary** RPCs are supported in gRPCServer v0.1. Server-streaming,
    client-streaming, and bidirectional RPCs are implemented but have known
    HTTP/2 lifecycle problems that are not yet fixed. Registering a streaming
    handler **throws** unless you explicitly opt in with
    `allow_unstable_streaming = true`. Do not enable streaming in production on
    this release.

## Why it is gated

The streaming runtime depends on fixes that currently live only in a patched
fork of the underlying HTTP.jl. Running streaming against the released HTTP.jl
exposes the issues below. They affect **client-streaming and bidirectional**
RPCs (and any case where the server finishes before the client half-closes its
request stream); plain unary request/response is unaffected.

1. **Successful RPCs reported as failures.** When the server sends its response
   before the client half-closes, the unread request body is reset with
   `RST_STREAM CANCEL`. Strict clients surface this as a transport error even
   though the RPC completed with `grpc-status OK`.

2. **Leaked tasks and connections.** A handler that returns before consuming the
   whole request stream can leave the per-stream reader task parked
   indefinitely, and the connection is classified as active forever, so it is
   never reaped by `idle_timeout`. Under sustained streaming load this grows
   memory and connection state.

3. **Graceful shutdown hangs.** Because such a connection never goes idle,
   `close(server)` can block. `forceclose(server)` is required to stop.

4. **Early rejections can surface as transport errors.** If the server rejects a
   request before reading its body (unknown method, bad content-type, non-POST,
   malformed `grpc-timeout`) while the client is still uploading, the client may
   see a `ProtocolError` instead of the trailers-only rejection with the proper
   `grpc-status`. This can affect unary calls too, but only on the rejection
   path.

## Enabling streaming at your own risk

If you understand the limitations and want to use streaming anyway (for example
in a controlled environment running the patched HTTP.jl fork), pass
`allow_unstable_streaming = true` when registering the handler:

```julia
handle!(router, MyService_Chat_Method(); allow_unstable_streaming = true) do in, out, ctx
    for m in in
        put!(out, reply(m))
    end
end
```

The generated `register_<Service>!` helper forwards the same keyword to its
streaming registrations:

```julia
register_MyService!(router; allow_unstable_streaming = true, Chat = chat_handler)
```

The handler signatures, when enabled, are:

| RPC type | Handler signature |
|----------|-------------------|
| Server streaming | `fn(req, out::Channel, ctx)` |
| Client streaming | `fn(in::Channel, ctx) -> resp` |
| Bidirectional | `fn(in::Channel, out::Channel, ctx)` |

See [Handlers](handlers.md) and [Concurrency](concurrency.md) for the runtime
model.
