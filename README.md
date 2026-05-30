# gRPCServer.jl

A gRPC server for Julia built on [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl)'s
HTTP/2 support, with code generation through
[ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl). It is the server
counterpart to [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl): same
wire protocol and the same ProtoBuf.jl codegen integration, but using HTTP.jl
instead of libCURL for transport.

Both cleartext HTTP/2 (h2c) and HTTP/2 over TLS (h2) are supported.

## Code generation

Register the codegen handler (done automatically when the package is loaded),
then run ProtoBuf.jl's `protojl` on your `.proto` files. For each `service`,
gRPCServer emits one descriptor constant per RPC plus a `register_<Service>!`
convenience:

```julia
using ProtoBuf, gRPCServer
protojl("myservice.proto", "proto", "gen"; always_use_modules=true)
```

If gRPCClient.jl is also loaded, a single `protojl` run emits both client stubs
and server descriptors into the same generated file.

## Serving

Handlers receive the decoded request and a context object whose `payload` field
carries user application state attached at `serve` time (the pattern used by
[Oxygen.jl](https://github.com/OxygenFramework/Oxygen.jl)):

```julia
using gRPCServer
include("gen/myservice/myservice_pb.jl")

struct AppState
    db
end

router = gRPCRouter()
register_MyService!(router;
    # unary: fn(req, ctx) -> resp
    GetThing = (req, ctx) -> Thing(query(ctx.payload.db, req.id)),
    # server streaming: fn(req, out::Channel, ctx)
    ListThings = (req, out, ctx) -> (for t in things(ctx.payload.db); put!(out, t); end),
    # client streaming: fn(in::Channel, ctx) -> resp
    UploadThings = (in, ctx) -> Summary(count(in)),
    # bidirectional: fn(in::Channel, out::Channel, ctx)
    Chat = (in, out, ctx) -> (for m in in; put!(out, reply(m)); end),
)

server = serve!(router, "0.0.0.0", 50051; context = AppState(open_db()))
# ... wait(server) to block, close(server) for graceful shutdown
```

Handlers can also be registered individually against the generated descriptors:

```julia
handle!(router, MyService_GetThing_Method) do req, ctx
    Thing(query(ctx.payload.db, req.id))
end
```

To control the response status, throw a `gRPCServiceCallException(status, message)`;
it is surfaced to the caller as the `grpc-status` / `grpc-message` trailers. Any
other exception becomes `INTERNAL`.

### TLS

```julia
serve!(router, "0.0.0.0", 443;
    tls = true, cert_file = "cert.pem", key_file = "key.pem")
```

### Task stickiness

By default the streaming pump tasks are migratable (`Threads.@spawn`), which
lets CPU-bound handlers use per-request multithreading. Pass `sticky = true` to
pin them to their spawning thread (Oxygen's `@async` behavior), which can suit
IO-bound workloads.

## Context API

- `metadata(ctx, key, default="")`: read a request metadata header
- `set_initial_metadata!(ctx, key, value)`: queue a response header
- `set_trailing_metadata!(ctx, key, value)`: queue a trailing-metadata header
- `deadline_exceeded(ctx)` / `iscancelled(ctx)`: cooperative deadline and
  cancellation checks
