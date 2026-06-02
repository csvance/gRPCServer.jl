# Getting Started

This guide takes you from a `.proto` file to a running server and a client call.

## 1. Install

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaIO/gRPCServer.jl")
```

## 2. Generate code from your `.proto`

Loading gRPCServer registers its code generation handler automatically, so a
single `protojl` run emits both the ProtoBuf message types and the gRPCServer
service descriptors. See [Code Generation](code_generation.md) for details.

```julia
using ProtoBuf, gRPCServer
protojl("myservice.proto", "proto", "gen"; always_use_modules = true)
```

For each `service`, this writes one `<Service>_<Rpc>_Method` descriptor builder
per RPC plus a `register_<Service>!` convenience function.

## 3. Write handlers and build a router

Handlers receive the decoded request and a [`gRPCContext`](@ref) whose `payload`
field carries the user application state you attach at serve time (the pattern
used by [Oxygen.jl](https://github.com/OxygenFramework/Oxygen.jl)).

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
```

The four handler signatures are documented in detail on the
[Handlers](handlers.md) page.

## 4. Serve

[`serve!`](@ref) starts the server in the background and returns an
`HTTP.Server`. [`serve`](@ref) is the blocking variant.

```julia
server = serve!(router, "0.0.0.0", 50051; context = AppState(open_db()))

# wait(server)  # block until the server stops
# close(server) # graceful shutdown
```

The value passed as `context` is what each handler reads through `ctx.payload`.

## 5. Call it

Use any gRPC client. With the sibling
[gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl), the same `protojl`
run that produced the server descriptors also produces the client stubs, so a
client can call the running server directly.

## Next steps

- Serve over TLS: see [TLS](tls.md).
- Control parallelism and the sticky task mode: see [Concurrency](concurrency.md).
- Tune message sizes, timeouts, and HTTP/2 windows for production: see
  [Security](security.md) and [Performance](performance.md).
