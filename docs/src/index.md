# gRPCServer.jl

A gRPC server for Julia built on [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl)'s
HTTP/2 support, with code generation through
[ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl). It is the server
counterpart to [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl): the
same wire protocol and the same ProtoBuf.jl codegen integration, using HTTP.jl
instead of libCURL for transport.

Both cleartext HTTP/2 (h2c) and HTTP/2 over TLS (h2) are supported.

## Features

- All four gRPC method types: unary, server streaming, client streaming, and
  bidirectional streaming
- ProtoBuf.jl code generation that emits per-RPC descriptors and a
  `register_<Service>!` helper per service
- An Oxygen.jl-style router with user application state attached at serve time
- Cooperative deadline and cancellation checks, request and response metadata
- Per-request multithreading by default, with an opt-in sticky (thread-pinned)
  task mode for IO-bound work
- A concurrency cap with load shedding, bounded message sizes, and configurable
  HTTP/2 flow-control windows
- Optional raw request and response buffers for partial decoding or byte
  forwarding

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaIO/gRPCServer.jl")
```

gRPCServer currently depends on a fork of HTTP.jl that adds configurable HTTP/2
flow-control window sizes. See the package `Project.toml` for the pinned source.

## Where to next

- [Getting Started](getting_started.md) walks through generating code, writing a
  handler, and serving it end to end.
- [Code Generation](code_generation.md) covers the ProtoBuf.jl integration.
- [Handlers](handlers.md) documents the four RPC patterns, raw buffers, error
  handling, and the context API.
- [Concurrency](concurrency.md) explains the threading model, sticky tasks, the
  concurrency cap, and deadlines.
- [TLS](tls.md), [Performance](performance.md), and [Security](security.md)
  cover deployment concerns.
- [API Reference](api.md) lists the full public interface.
