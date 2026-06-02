# Security

This package decodes untrusted, network-supplied frames, so deployments should
account for the following.

## Authentication and authorization

Authentication and authorization are the application's responsibility. The server
does not authenticate callers. A handler reads credentials from request metadata
(`metadata(ctx, "authorization")` and similar) and throws
`gRPCServiceCallException(GRPC_UNAUTHENTICATED, ...)` or `GRPC_PERMISSION_DENIED`
to reject the call. There is no built-in mutual TLS or client-certificate
verification.

## Transport

Use TLS in production. The default is cleartext HTTP/2 (h2c); pass `tls = true`
with `cert_file` and `key_file` to serve h2. Cleartext should only be used behind
a trusted boundary, for example a localhost sidecar or a TLS-terminating proxy.
See [TLS](tls.md).

## Message size limits

Message size is bounded by
`gRPCRouter(; max_receive_message_length, max_send_message_length)` (4 MiB each
by default). Oversized frames are rejected with `GRPC_RESOURCE_EXHAUSTED` before
the payload is buffered. Note this bounds a *single* message; aggregate in-flight
memory still scales with the number of concurrent streams.

## Concurrency cap

`max_concurrent_requests` (a [`serve!`](@ref) keyword, `0` = unlimited) caps how
many RPCs run at once and sheds excess load with `GRPC_RESOURCE_EXHAUSTED`,
bounding that aggregate exposure. Set it to a value sized to the host's memory
and the configured `max_receive_message_length`. See
[Concurrency](concurrency.md#Concurrency-cap-and-load-shedding).

## Connection timeouts

Connection timeouts default to `read_header_timeout = 30` and
`idle_timeout = 300` seconds, which reap slow-header and idle connections without
disturbing established streams. `read_timeout` and `write_timeout` are disabled
by default; enabling them defends against a peer that trickles or never finishes
a request or response body, but a non-zero `read_timeout` also terminates
legitimately idle long-lived streaming RPCs, so set it only for unary or
short-lived workloads.
