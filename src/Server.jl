# HTTP.jl integration: the server entry points and the per-request dispatch.

# Build "host:port", bracketing IPv6 literals.
_join_host_port(host::AbstractString, port::Integer) =
    occursin(':', host) ? "[$host]:$(port)" : "$host:$(port)"

"""
    serve!(router, host="127.0.0.1", port=50051; kwargs...) -> HTTP.Server

Start a gRPC server in the background and return the running `HTTP.Server`. Use
`wait(server)` to block and `close(server)` for a graceful shutdown.

Keyword arguments:
- `context`: user application state surfaced to handlers as `ctx.payload::T`.
- `tls`, `cert_file`, `key_file`, `alpn_protocols`: enable HTTP/2 over TLS (h2).
  When `tls=false` (default) the server speaks cleartext HTTP/2 (h2c).
- `sticky`: spawn the streaming pump tasks sticky (`@async`) instead of
  migratable (`Threads.@spawn`). Default `false`. See the package docs.
- `read_timeout`, `write_timeout`, `idle_timeout`, `reuseaddr`, `backlog`,
  `max_header_bytes`: forwarded to `HTTP.listen!`.
"""
function serve!(
    router::gRPCRouter,
    host::AbstractString = "127.0.0.1",
    port::Integer = 50051;
    context = nothing,
    tls::Bool = false,
    cert_file::Union{Nothing,AbstractString} = nothing,
    key_file::Union{Nothing,AbstractString} = nothing,
    alpn_protocols::Vector{String} = ["h2"],
    sticky::Bool = false,
    read_timeout = nothing,
    write_timeout = nothing,
    idle_timeout = nothing,
    max_header_bytes::Integer = 1024 * 1024,
    reuseaddr::Bool = true,
    backlog::Integer = 128,
)
    handler = stream -> dispatch(router, stream, context, sticky)

    if tls
        (cert_file === nothing || key_file === nothing) &&
            throw(ArgumentError("tls=true requires both cert_file and key_file"))
        config = Reseau.TLS.Config(;
            cert_file = cert_file,
            key_file = key_file,
            alpn_protocols = alpn_protocols,
        )
        listener = Reseau.TLS.listen(
            "tcp",
            _join_host_port(host, port),
            config;
            backlog = backlog,
            reuseaddr = reuseaddr,
        )
        return HTTP.listen!(
            handler,
            listener;
            read_timeout = read_timeout,
            write_timeout = write_timeout,
            idle_timeout = idle_timeout,
            max_header_bytes = max_header_bytes,
        )
    else
        return HTTP.listen!(
            handler,
            host,
            Int(port);
            read_timeout = read_timeout,
            write_timeout = write_timeout,
            idle_timeout = idle_timeout,
            max_header_bytes = max_header_bytes,
            reuseaddr = reuseaddr,
            backlog = backlog,
        )
    end
end

"""
    serve(router, host="127.0.0.1", port=50051; kwargs...)

Like [`serve!`](@ref) but blocks until the server is closed, then shuts it down.
"""
function serve(router::gRPCRouter, args...; kwargs...)
    server = serve!(router, args...; kwargs...)
    try
        wait(server)
    finally
        close(server)
    end
    return server
end

# Build the per-request context, parsing the deadline from grpc-timeout.
function _build_context(stream::HTTP.Stream, request, payload)
    deadline_ns = parse_grpc_timeout(HTTP.header(request.headers, "grpc-timeout", ""))
    return gRPCContext(payload, request.target, request.headers, "", deadline_ns, stream)
end

# Send the response head (status 200 + grpc content-type + any initial
# metadata) exactly once, leaving Content-Length unset so trailers flush at
# closewrite. Idempotent.
function _start_response!(stream::HTTP.Stream, ctx::gRPCContext)
    ctx.initial_sent && return nothing
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type", "application/grpc")
    for (k, v) in ctx.initial_metadata
        HTTP.setheader(stream, k, v)
    end
    HTTP.startwrite(stream)
    ctx.initial_sent = true
    return nothing
end

# Emit trailing metadata + grpc-status / grpc-message, then close the write side.
function _emit_trailers(stream::HTTP.Stream, ctx::gRPCContext, status::Integer, message::AbstractString)
    for (k, v) in ctx.trailing_metadata
        HTTP.addtrailer(stream, k => v)
    end
    HTTP.addtrailer(stream, "grpc-status" => string(status))
    isempty(message) || HTTP.addtrailer(stream, "grpc-message" => percent_encode(message))
    HTTP.closewrite(stream)
    return nothing
end

# Trailers-only response (no body): used for unknown methods and pre-handler
# rejections.
function _trailers_only(stream::HTTP.Stream, status::Integer, message::AbstractString)
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type", "application/grpc")
    HTTP.startwrite(stream)
    HTTP.addtrailer(stream, "grpc-status" => string(status))
    isempty(message) || HTTP.addtrailer(stream, "grpc-message" => percent_encode(message))
    HTTP.closewrite(stream)
    return nothing
end

function _finish_ok(stream::HTTP.Stream, ctx::gRPCContext)
    _start_response!(stream, ctx)
    _emit_trailers(stream, ctx, GRPC_OK, "")
    return nothing
end

function _finish_error(stream::HTTP.Stream, ctx::gRPCContext, err)
    if err isa gRPCServiceCallException
        _start_response!(stream, ctx)
        _emit_trailers(stream, ctx, err.grpc_status, err.message)
    elseif _is_cancellation(err)
        @debug "gRPC stream cancelled by peer" path = ctx.path
    elseif deadline_exceeded(ctx)
        try
            _start_response!(stream, ctx)
            _emit_trailers(stream, ctx, GRPC_DEADLINE_EXCEEDED, "Deadline exceeded.")
        catch
        end
    else
        @error "gRPC handler error" exception = (err, catch_backtrace()) path = ctx.path
        try
            _start_response!(stream, ctx)
            _emit_trailers(stream, ctx, GRPC_INTERNAL, "internal error")
        catch
        end
    end
    return nothing
end

"""
    dispatch(router, stream, payload, sticky)

Handle one inbound HTTP/2 stream: validate, route, build the context, invoke the
handler, and emit the closing gRPC trailers.
"""
function dispatch(router::gRPCRouter, stream::HTTP.Stream, payload, sticky::Bool)
    request = HTTP.startread(stream)

    ct = HTTP.header(request.headers, "Content-Type", "")
    if !_is_grpc_content_type(ct)
        try
            _trailers_only(stream, GRPC_INTERNAL, "invalid content-type: $ct")
        catch
        end
        return nothing
    end

    entry = get(router.routes, request.target, nothing)
    if entry === nothing
        try
            _trailers_only(stream, GRPC_UNIMPLEMENTED, "Method not found: $(request.target)")
        catch
        end
        return nothing
    end

    ctx = _build_context(stream, request, payload)
    ctx.sticky = sticky

    try
        entry.dispatch(stream, ctx)
        _finish_ok(stream, ctx)
    catch err
        _finish_error(stream, ctx, err)
    finally
        try
            HTTP.closeread(stream)
        catch
        end
    end
    return nothing
end
