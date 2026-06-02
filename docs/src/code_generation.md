# Code Generation

gRPCServer integrates with [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl)
through an external code generation handler. Loading the package registers that
handler from its `__init__`, so you do not normally call anything by hand; you
just run ProtoBuf.jl's `protojl` on your `.proto` files.

```julia
using ProtoBuf, gRPCServer
protojl("myservice.proto", "proto", "gen"; always_use_modules = true)
```

For each `service` in the `.proto`, gRPCServer emits:

- one `<Service>_<Rpc>_Method` descriptor builder per RPC, and
- a `register_<Service>!(router; ...)` convenience function.

If [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) is also loaded, a
single `protojl` run emits both client stubs and server descriptors into the
same generated file.

## Descriptor builders

Each `*_Method` is a builder function (mirroring gRPCClient.jl's `*_Client`
constructor) whose `TRequest` and `TResponse` keyword arguments default to the
proto message types. You register a handler against a descriptor with
[`handle!`](@ref):

```julia
handle!(router, MyService_GetThing_Method()) do req, ctx
    Thing(query(ctx.payload.db, req.id))
end
```

Overriding `TRequest` or `TResponse` with `Vector{UInt8}` opts a side into raw,
undecoded protobuf bytes. See [Raw request and response buffers](handlers.md#Raw-request-and-response-buffers)
on the Handlers page.

## The `register_<Service>!` helper

`register_<Service>!` registers several handlers at once by RPC name, which is
the most concise way to wire up a service:

```julia
register_MyService!(router;
    GetThing = (req, ctx) -> Thing(query(ctx.payload.db, req.id)),
    ListThings = (req, out, ctx) -> (for t in things(ctx.payload.db); put!(out, t); end),
)
```

Any RPC left unset is simply not registered.

## Re-registering the handler

The codegen handler is registered automatically on load. If a host needs to
register it again explicitly, call [`grpc_register_service_codegen`](@ref).
