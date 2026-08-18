# Security Hardening

How to deploy gRPCServer.jl safely, and what it does not do for you.

Start with the next section. Several protections people commonly expect of a
gRPC server are the integrator's responsibility here, and knowing which ones is
what changes how you deploy.

## What this server does not do

- **No authentication.** `AuthInterceptor` is an example, not a mechanism.
- **No authorization.** No caller identity, no per-method policy.
- **No rate limiting.** `max_concurrent_requests` bounds concurrency, not rate.
- **No mid-execution deadline enforcement.** A handler that runs past its
  deadline is *not* interrupted.
- **No mTLS identity for handlers.** mTLS authenticates the peer but the
  verified identity is not exposed, so you cannot authorize on it.
- **No protection against a malicious handler.** Handlers run in-process with
  full privileges.

Each is expanded below. Guarantees also differ by HTTP/2 backend — see
[Backend choice](@ref).

## A production baseline

Every setting below is explained in the sections that follow.

```julia
using gRPCServer

tls = TLSConfig(
    cert_chain = "/etc/certs/server.crt",
    private_key = "/etc/certs/server.key",
    client_ca = "/etc/certs/ca.crt",   # service-to-service: verify callers
    require_client_cert = true,
    min_version = :TLSv1_3,
)

server = GRPCServer("0.0.0.0", 50051;
    tls = tls,
    debug_mode = false,                       # never true in production
    enable_reflection = false,                # discloses your schema
    max_message_size = 4 * 1024 * 1024,       # size to your workload
    max_concurrent_requests = 512,            # size to your memory
    max_concurrent_streams = 100,
    idle_timeout = 300.0,                     # reap stalled connections
    read_header_timeout = 30.0,
)
```

The default backend (`HTTPjlBackend`) is the only one recommended for exposed
deployments — see [Backend choice](@ref) below.

## Size the limits to your host, not to the defaults

The shipped defaults are conservative, not correct for your workload. Two of them
deserve deliberate choice.

**`max_message_size`** (default 4 MiB) bounds a single message in each direction.
On the default backend it is enforced on the receive side *before any payload is
buffered*, so an oversized declaration is refused without allocating (see
[Backend choice](@ref) for how this differs on `Nghttp2Backend`). Set it to the
largest message your service legitimately handles, and no larger: it is the
multiplier on every other memory bound.

**`max_concurrent_requests`** (default 1024) caps in-flight handler tasks. Calls
arriving past the cap are shed immediately with a trailers-only
`RESOURCE_EXHAUSTED` — there is no queue. This matters more than it looks:
HTTP.jl permits 100 concurrent streams per connection, so without a cap, N
connections imply 100·N concurrent handler tasks.

A useful way to pick it:

```
max_concurrent_requests ≈ available_memory_for_requests / (max_message_size × k)
```

where `k` accounts for what your handler allocates per request beyond the
message itself. Err low — shedding is recoverable, an out-of-memory kill is not.

## Bound your handlers yourself

This is the sharpest edge in the package, so it is worth stating plainly:

!!! warning "Deadlines are not enforced mid-execution"
    `grpc-timeout` is parsed into `ctx.deadline` and checked at two points —
    before dispatch (fail-fast) and after the handler returns. A handler that
    runs past its deadline is **not interrupted**. It runs to completion, and its
    result is then mapped to `DEADLINE_EXCEEDED`.

An expensive handler plus a peer willing to open connections is a denial of
service regardless of what the client asked for. Any handler that can run long
must cooperate:

```julia
function my_handler(ctx, req)
    for chunk in work_items(req)
        is_cancelled(ctx) && throw(GRPCError(StatusCode.CANCELLED, "client went away"))
        remaining_time(ctx) < 0.1 && throw(GRPCError(StatusCode.DEADLINE_EXCEEDED, "out of time"))
        process(chunk)
    end
    return build_response()
end
```

`TimeoutInterceptor` helps, but it is also a pre-check only — it cannot interrupt
a running handler either.

## Authentication and authorization are yours to add

The package provides neither. `AuthInterceptor` in the sources is an *example*,
not a mechanism: there is no credential validation, no token verification, no
notion of a caller identity or a per-method policy.

```julia
struct BearerAuth <: Interceptor
    verify::Function        # your token verification
end

function (i::BearerAuth)(ctx, request, info, next)
    token = get_metadata_string(ctx, "authorization")
    token === nothing && throw(GRPCError(StatusCode.UNAUTHENTICATED, "missing credentials"))
    i.verify(token) || throw(GRPCError(StatusCode.UNAUTHENTICATED, "invalid credentials"))
    return next(ctx, request)
end
```

!!! note "mTLS authenticates but cannot authorize"
    With `require_client_cert = true` an unverified client cannot complete a
    connection. But the verified peer identity is **not** exposed to handlers
    (`peer_cert_subject` is always `nothing`), so you cannot write "only the
    client presenting CN `svc-billing` may call this method". Per-caller
    authorization must come from application metadata, or from a proxy that
    terminates mTLS and forwards the verified identity as a header.

There is also **no rate limiting**: `max_concurrent_requests` bounds concurrency,
not rate. A peer issuing a fast sequence of cheap calls is unthrottled. Add an
interceptor or put a proxy in front.

## Response metadata

Header and trailer names you set are validated before emission. Runtime-owned
names (`grpc-status`, `grpc-message`, `content-type`, `grpc-encoding`, …),
pseudo-headers, names outside the gRPC metadata charset, and values containing
CR, LF or NUL are dropped with a warning.

This protects the case where a handler echoes client-controlled data:

```julia
# Safe: an attacker-controlled value cannot append a second grpc-status,
# inject a pseudo-header, or smuggle CRLF into the response.
set_trailer!(ctx, "x-request-id", untrusted_id_from_request)
```

Binary values use the `-bin` suffix and are base64-encoded, so raw bytes are fine
there.

## Backend choice

`HTTPjlBackend` is the default and the only backend recommended for untrusted
traffic. The others are opt-in and experimental, and they do not offer the same
protections.

| Protection | `HTTPjlBackend` | `PureHTTP2Backend` | `Nghttp2Backend` |
|---|---|---|---|
| Receive message cap | ✅ allocation | ✅ allocation | ⚠️ processing only |
| Decompression cap | ✅ | ✅ | ✅ |
| Connection timeouts | ✅ | ❌ | ❌ |
| mTLS | ✅ | ✅ | ❌ ignored |
| TLS `min_version`, ALPN | ✅ | ✅ | ❌ ignored |

!!! danger "The receive cap does not bound allocation on `Nghttp2Backend`"
    All three backends enforce `max_receive_message_length`. But
    `HTTPjlBackend` and `PureHTTP2Backend` refuse the length prefix *before
    reading the payload*, so the cap bounds what the server allocates.
    Nghttp2Wrapper's handler is buffered — the whole request body is in memory
    before the cap is consulted — so there it bounds only what the server
    processes. Do not expose `Nghttp2Backend` to untrusted peers.

Where a backend cannot honour a keyword, setting it explicitly raises
`UnsupportedFeatureError` at construction rather than being silently ignored.

When selecting `PureHTTP2Backend`, use `import PureHTTP2`, not `using` — both
load the extension, but `using` makes `get_metadata` and `set_header!` ambiguous,
since both packages export those names.

## Certificates

Key material is checked structurally when the server is built: a truncated,
empty, or non-PEM file is refused at startup rather than failing at the first
handshake. The check is not cryptographic — key/certificate correspondence and
expiry are still decided during the handshake.

`reload_tls!` swaps certificates without rebinding the socket, and leaves the
transport untouched if the new material cannot be loaded.

## Checklist

1. `HTTPjlBackend` (the default) for anything exposed.
2. TLS on; mTLS for service-to-service, knowing the identity limitation above.
3. `debug_mode = false`.
4. `enable_reflection = false` on untrusted networks.
5. `max_message_size` and `max_concurrent_requests` sized to your host.
6. Cooperative deadline checks in any long-running handler.
7. Authentication and rate limiting added by you.
8. `idle_timeout` left on, to reap stalled connections.
