# Concurrency

This page covers how the server runs handlers across tasks and threads, the
sticky task option, the concurrency cap, and cooperative deadlines.

## Threading model

The server is built on HTTP.jl, which spawns one task per inbound HTTP/2 stream.
That per-stream task is where your handler runs:

- **Unary** and **client-streaming** handlers run directly on the per-stream
  task. Nothing extra is spawned for the handler itself.
- **Server-streaming** and **bidirectional** handlers additionally use pump
  tasks that move messages between the socket and the request and response
  `Channel`s, so handler logic is decoupled from frame I/O. A feeder task
  decodes incoming frames onto the input channel; a drainer task writes outgoing
  messages from the output channel. The handler runs on the original stream
  task.

Because each connection and each stream is independent, many RPCs are served
concurrently as a matter of course.

## Sticky versus migratable tasks

The pump tasks are spawned through a single internal seam that selects one of
two strategies based on the `sticky` keyword you pass to [`serve!`](@ref):

- `sticky = false` (the default) spawns with `Threads.@spawn`. The tasks are
  **migratable**: the Julia scheduler may run them on any thread in the default
  pool. This lets CPU-bound handlers use per-request multithreading.
- `sticky = true` spawns with `@async`. The tasks are **pinned** to the thread
  that spawned them (the behavior Oxygen.jl uses), which can suit IO-bound
  workloads where thread affinity reduces scheduling overhead.

```julia
# Default: migratable, good for CPU-bound work with multiple threads
serve!(router, "0.0.0.0", 50051)

# Pinned: good for IO-bound work
serve!(router, "0.0.0.0", 50051; sticky = true)
```

The flag flows through the context to every pump task spawned for a request.

## Running with multiple threads

Migratable tasks only parallelize across threads if Julia is started with more
than one. Launch with a thread count to benefit from the default mode:

```
julia --threads=auto --project myserver.jl
```

With a single thread, tasks still interleave cooperatively at I/O and channel
boundaries, but CPU-bound handlers will not run in parallel.

Handler thread safety is the application's responsibility. When `sticky` is
`false`, two handlers can execute simultaneously on different threads and share
whatever you attached as `context`. Guard mutable shared state (database
connection pools, caches, counters) with the appropriate locks or atomics.

## Concurrency cap and load shedding

Without a cap, the number of in-flight handlers is bounded only by what clients
send, so memory use can grow without limit. The `max_concurrent_requests`
keyword on [`serve!`](@ref) (default `0`, meaning unlimited) caps how many RPCs
run at once. The dispatcher tracks in-flight requests with a shared atomic
counter; when the cap is reached, additional requests are shed immediately with
a `GRPC_RESOURCE_EXHAUSTED` trailer rather than being queued.

```julia
serve!(router, "0.0.0.0", 50051; max_concurrent_requests = 256)
```

Size the cap to the host's memory and the configured
`max_receive_message_length` (see [Security](security.md)).

## Deadlines and cancellation

A client may send a `grpc-timeout` header; the server parses it into an absolute
deadline on the [`gRPCContext`](@ref). Long-running and streaming handlers should
cooperatively check it and return early, since Julia tasks are not forcibly
interrupted:

- [`deadline_exceeded`](@ref)`(ctx)` returns `true` once the request deadline has
  passed.
- [`iscancelled`](@ref)`(ctx)` returns `true` if the request has been cancelled.

```julia
handle!(router, MyService_ListThings_Method()) do req, out, ctx
    for t in things(ctx.payload.db)
        (deadline_exceeded(ctx) || iscancelled(ctx)) && break
        put!(out, t)
    end
end
```
