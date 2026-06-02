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
gRPCServer emits one descriptor builder per RPC plus a `register_<Service>!`
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

Handlers can also be registered individually against the generated descriptors.
Each `*_Method` is a builder function (mirroring gRPCClient.jl's `*_Client`
constructor) whose `TRequest` / `TResponse` keyword arguments default to the proto
message types:

```julia
handle!(router, MyService_GetThing_Method()) do req, ctx
    Thing(query(ctx.payload.db, req.id))
end
```

#### Raw request / response buffers (partial decoding)

Override `TRequest` and/or `TResponse` with `Vector{UInt8}` to have the handler
receive the raw, undecoded protobuf payload and/or return raw response bytes,
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

## Security

This package decodes untrusted, network-supplied frames, so deployments should
account for the following.

- Authentication and authorization are the application's responsibility. The
  server does not authenticate callers; a handler reads credentials from request
  metadata (`metadata(ctx, "authorization")`, etc.) and throws
  `gRPCServiceCallException(GRPC_UNAUTHENTICATED, ...)` or `GRPC_PERMISSION_DENIED`
  to reject. There is no built-in mutual TLS / client-certificate verification.
- Use TLS in production. The default is cleartext HTTP/2 (h2c); pass `tls = true`
  with `cert_file` / `key_file` to serve h2. Cleartext should only be used behind
  a trusted boundary (for example a localhost sidecar or a TLS-terminating proxy).
- Message size is bounded by `gRPCRouter(; max_recieve_message_length, max_send_message_length)`
  (4 MiB each by default). Oversized frames are rejected with `RESOURCE_EXHAUSTED`
  before the payload is buffered. Note this bounds a *single* message; aggregate
  in-flight memory still scales with the number of concurrent streams.
- `max_concurrent_requests` (a `serve!` keyword, `0` = unlimited) caps how many
  RPCs run at once and sheds excess load with `RESOURCE_EXHAUSTED`, bounding that
  aggregate exposure. Set it to a value sized to the host's memory and the
  configured `max_recieve_message_length`.
- Connection timeouts default to `read_header_timeout = 30` and
  `idle_timeout = 300` seconds, which reap slow-header and idle connections
  without disturbing established streams. `read_timeout` and `write_timeout` are
  disabled by default; enabling them defends against a peer that trickles or
  never finishes a request/response body, but a non-zero `read_timeout` also
  terminates legitimately idle long-lived streaming RPCs, so set it only for
  unary or short-lived workloads.

## Performance

The framing layer reads request bytes directly into a single reusable buffer and
hands the decoder a view into it, so a received message is not copied between the
socket and ProtoBuf decoding. A throughput and allocation benchmark lives under
`benchmark/`:

```
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'   # first time
julia --project=benchmark --threads=auto benchmark/run.jl
```

### HTTP/2 flow-control window and large uploads

Large client to server messages (big request protobufs and client-streaming) are
bounded by the HTTP/2 flow-control window. At the protocol-default 64 KiB stream
and connection windows, in-flight upload bytes are capped near 64 KiB, so upload
throughput is limited to roughly window / round-trip-time. On localhost this is
invisible, but over a network with a 10 ms round trip it caps uploads near 6 MB/s
regardless of message size. Downloads (server to client) are not affected the same
way, since HTTP.jl already batches outgoing DATA frames.

`serve!` exposes three keywords that raise the windows, forwarded to `HTTP.listen!`
(they require the vendored HTTP.jl fork that implements them; see `Project.toml`).
All default to the protocol defaults, so behavior is unchanged unless set:

- `h2_initial_window_size` (default 65535): the per-stream receive window the
  server advertises via `SETTINGS_INITIAL_WINDOW_SIZE`
- `h2_connection_window_size` (default 65535): the connection-level receive window,
  applied with an initial `WINDOW_UPDATE` when above 65535
- `h2_max_buffered_bytes` (default 262144): the per-stream receive buffer cap. It
  must be at least `h2_initial_window_size`

```julia
# Size the window to the bandwidth-delay product, e.g. 8 MiB for a high-BDP link.
serve!(router, "0.0.0.0", 50051;
    h2_initial_window_size = 8 * 1024 * 1024,
    h2_connection_window_size = 8 * 1024 * 1024,
    h2_max_buffered_bytes = 8 * 1024 * 1024)
```

To benefit in both directions, the client must advertise a matching receive window,
since an endpoint's send throughput is governed by the peer's advertised window.

Transport tuning that is sometimes expected but does not apply here: there is no
TCP send/receive buffer size knob in HTTP.jl 2.0 or its Reseau transport (the
kernel autotunes), and `TCP_NODELAY` is already enabled by default, so small
messages are not delayed by Nagle.
