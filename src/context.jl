# Server context for gRPCServer.jl

using UUIDs
using Dates
using Sockets

"""
    PeerInfo

Client connection information.

# Fields
- `address::Union{IPv4, IPv6}`: Client IP address
- `port::Int`: Client port
- `certificate::Union{Vector{UInt8}, Nothing}`: Client certificate for mTLS (DER-encoded)

# Example
```julia
peer = ctx.peer
@info "Client connected from \$(peer.address):\$(peer.port)"
```
"""
struct PeerInfo
    address::Union{IPv4, IPv6}
    port::Int
    certificate::Union{Vector{UInt8}, Nothing}

    PeerInfo(address::Union{IPv4, IPv6}, port::Int;
             certificate::Union{Vector{UInt8}, Nothing}=nothing) =
        new(address, port, certificate)
end

function Base.show(io::IO, peer::PeerInfo)
    print(io, "PeerInfo($(peer.address):$(peer.port)")
    if peer.certificate !== nothing
        print(io, ", mTLS")
    end
    print(io, ")")
end

"""
    ServerContext

Request-scoped context provided to handler functions.

# Fields
- `request_id::UUID`: Unique identifier for this request
- `method::String`: Full method path (e.g., "/helloworld.Greeter/SayHello")
- `authority::String`: Authority from :authority pseudo-header
- `metadata::Dict{String, Union{String, Vector{UInt8}}}`: Request metadata
- `response_headers::Dict{String, Union{String, Vector{UInt8}}}`: Response headers to send
- `trailers::Dict{String, Union{String, Vector{UInt8}}}`: Trailing metadata to send
- `deadline::Union{DateTime, Nothing}`: Request deadline (nothing = no deadline). The server does **not** interrupt a handler when the deadline passes — it is enforced only before dispatch (fail-fast) and after the handler returns (see [`ServerConfig`](@ref) deadline semantics); handlers should check [`remaining_time`](@ref)/[`is_cancelled`](@ref) cooperatively to bound their own runtime.
- `cancelled::Bool`: Whether the request has been cancelled
- `peer::PeerInfo`: Client connection information
- `trace_context::Union{Vector{UInt8}, Nothing}`: Distributed tracing context
- `payload::Any`: Arbitrary server-side payload (unused by the transport)

# Example
```julia
function say_hello(ctx::ServerContext, request::HelloRequest)::HelloReply
    @info "Request" id=ctx.request_id method=ctx.method

    # Check cancellation
    if is_cancelled(ctx)
        throw(GRPCError(StatusCode.CANCELLED, "Request cancelled"))
    end

    # Set response header
    set_header!(ctx, "x-request-id", string(ctx.request_id))

    # Check deadline
    remaining = remaining_time(ctx)
    if remaining !== nothing && remaining < 0
        throw(GRPCError(StatusCode.DEADLINE_EXCEEDED, "Deadline exceeded"))
    end

    HelloReply(message = "Hello, \$(request.name)!")
end
```
"""
mutable struct ServerContext
    request_id::UUID
    method::String
    authority::String
    metadata::Dict{String, Union{String, Vector{UInt8}}}
    response_headers::Dict{String, Union{String, Vector{UInt8}}}
    trailers::Dict{String, Union{String, Vector{UInt8}}}
    deadline::Union{DateTime, Nothing}
    cancelled::Bool
    peer::PeerInfo
    trace_context::Union{Vector{UInt8}, Nothing}
    payload::Any

    function ServerContext(;
        method::String="",
        authority::String="",
        metadata::Dict{String, Union{String, Vector{UInt8}}}=Dict{String, Union{String, Vector{UInt8}}}(),
        deadline::Union{DateTime, Nothing}=nothing,
        peer::PeerInfo=PeerInfo(IPv4("0.0.0.0"), 0),
        trace_context::Union{Vector{UInt8}, Nothing}=nothing,
        payload::Any=nothing
    )
        new(
            uuid4(),
            method,
            authority,
            metadata,
            Dict{String, Union{String, Vector{UInt8}}}(),
            Dict{String, Union{String, Vector{UInt8}}}(),
            deadline,
            false,
            peer,
            trace_context,
            payload
        )
    end
end

"""
    set_header!(ctx::ServerContext, key::String, value::String)
    set_header!(ctx::ServerContext, key::String, value::Vector{UInt8})

Set a response header to be sent before the response body.

Headers must be set before the first response message is sent.
Binary headers should have a "-bin" suffix in the key name.

# Example
```julia
set_header!(ctx, "x-custom-header", "custom-value")
set_header!(ctx, "x-binary-data-bin", UInt8[0x01, 0x02, 0x03])
```
"""
function set_header!(ctx::ServerContext, key::String, value::String)
    ctx.response_headers[lowercase(key)] = value
end

function set_header!(ctx::ServerContext, key::String, value::Vector{UInt8})
    ctx.response_headers[lowercase(key)] = value
end

"""
    set_trailer!(ctx::ServerContext, key::String, value::String)
    set_trailer!(ctx::ServerContext, key::String, value::Vector{UInt8})

Set trailing metadata to be sent after the response body.

Trailers are sent at the end of the response stream and can be used
to communicate status information determined during processing.

# Example
```julia
set_trailer!(ctx, "x-processing-time", "150ms")
```
"""
function set_trailer!(ctx::ServerContext, key::String, value::String)
    ctx.trailers[lowercase(key)] = value
end

function set_trailer!(ctx::ServerContext, key::String, value::Vector{UInt8})
    ctx.trailers[lowercase(key)] = value
end

"""
    get_metadata(ctx::ServerContext, key::String) -> Union{String, Vector{UInt8}, Nothing}

Get request metadata by key (case-insensitive).

# Example
```julia
auth = get_metadata(ctx, "authorization")
if auth === nothing
    throw(GRPCError(StatusCode.UNAUTHENTICATED, "Missing authorization"))
end
```
"""
function get_metadata(ctx::ServerContext, key::String)::Union{String, Vector{UInt8}, Nothing}
    return get(ctx.metadata, lowercase(key), nothing)
end

"""
    get_metadata_string(ctx::ServerContext, key::String) -> Union{String, Nothing}

Get request metadata as a string (returns nothing for binary metadata).
"""
function get_metadata_string(ctx::ServerContext, key::String)::Union{String, Nothing}
    value = get_metadata(ctx, key)
    if value isa String
        return value
    end
    return nothing
end

"""
    get_metadata_binary(ctx::ServerContext, key::String) -> Union{Vector{UInt8}, Nothing}

Get request metadata as binary (converts strings to bytes if needed).
"""
function get_metadata_binary(ctx::ServerContext, key::String)::Union{Vector{UInt8}, Nothing}
    value = get_metadata(ctx, key)
    if value isa Vector{UInt8}
        return value
    elseif value isa String
        return Vector{UInt8}(value)
    end
    return nothing
end

"""
    remaining_time(ctx::ServerContext) -> Union{Float64, Nothing}

Get the remaining time until the deadline in seconds.

Returns `nothing` if no deadline is set.
Returns negative value if deadline has passed.

# Example
```julia
remaining = remaining_time(ctx)
if remaining !== nothing && remaining < 0
    throw(GRPCError(StatusCode.DEADLINE_EXCEEDED, "Deadline exceeded"))
end
```
"""
function remaining_time(ctx::ServerContext)::Union{Float64, Nothing}
    if ctx.deadline === nothing
        return nothing
    end
    return Dates.value(ctx.deadline - now()) / 1000.0  # Convert ms to seconds
end

"""
    is_cancelled(ctx::ServerContext) -> Bool

Check if the request has been cancelled by the client.

# Example
```julia
if is_cancelled(ctx)
    throw(GRPCError(StatusCode.CANCELLED, "Request cancelled by client"))
end
```
"""
function is_cancelled(ctx::ServerContext)::Bool
    return ctx.cancelled
end

"""
    cancel!(ctx::ServerContext)

Mark the request as cancelled.
"""
function cancel!(ctx::ServerContext)
    ctx.cancelled = true
end

# parse_grpc_timeout is defined in strict.jl (included before this file):
# strict spec-validated parsing (1-8 digits + unit, checked arithmetic) that
# returns a DateTime deadline and throws GRPCError(StatusCode.INVALID_ARGUMENT)
# on malformed non-empty values (empty = absent -> nothing).

"""
    format_grpc_timeout(deadline::DateTime) -> String

Format a deadline as a gRPC timeout header value.
"""
function format_grpc_timeout(deadline::DateTime)::String
    remaining_ms = max(0, Dates.value(deadline - now()))

    if remaining_ms >= 3600000
        hours = remaining_ms ÷ 3600000
        return "$(hours)H"
    elseif remaining_ms >= 60000
        minutes = remaining_ms ÷ 60000
        return "$(minutes)M"
    elseif remaining_ms >= 1000
        seconds = remaining_ms ÷ 1000
        return "$(seconds)S"
    else
        return "$(remaining_ms)m"
    end
end

"""
    create_context_from_headers(
        headers::Vector{Tuple{String, String}},
        peer::PeerInfo
    ) -> ServerContext

Create a ServerContext from HTTP/2 request headers.
"""
function create_context_from_headers(
    headers::Vector{Tuple{String, String}},
    peer::PeerInfo
)::ServerContext
    metadata = Dict{String, Union{String, Vector{UInt8}}}()
    method = ""
    authority = ""
    deadline = nothing
    trace_context = nothing

    for (name, value) in headers
        name_lower = lowercase(name)

        if name_lower == ":path"
            method = value
        elseif name_lower == ":authority"
            authority = value
        elseif name_lower == "grpc-timeout"
            deadline = parse_grpc_timeout(value)
        elseif name_lower == "grpc-trace-bin"
            # Binary header - should be base64 decoded
            trace_context = try
                base64decode(value)
            catch
                Vector{UInt8}(value)
            end
        elseif !startswith(name_lower, ":")
            # Custom metadata
            if endswith(name_lower, "-bin")
                # Binary metadata - base64 decode
                try
                    metadata[name_lower] = base64decode(value)
                catch
                    metadata[name_lower] = Vector{UInt8}(value)
                end
            else
                metadata[name_lower] = value
            end
        end
    end

    return ServerContext(;
        method=method,
        authority=authority,
        metadata=metadata,
        deadline=deadline,
        peer=peer,
        trace_context=trace_context
    )
end

# --- Response-metadata validation -------------------------------------------
#
# Handler-supplied header/trailer names and values are emitted onto the wire, so
# they are validated at this choke point (every backend formats its response
# metadata through the two functions below). Without it a handler that echoes
# client-controlled data into a header could:
#
#   * emit a second `grpc-status` trailer, since the runtime's own value is
#     pushed first and the handler's is appended — a client that reads the last
#     occurrence sees the handler's, turning a PERMISSION_DENIED into an OK;
#   * emit a pseudo-header such as `:path` after the regular fields, which HTTP/2
#     forbids in a response and requires a peer to treat as malformed;
#   * put CR, LF or NUL in a value, which RFC 9113 §8.2.1 forbids outright and
#     which becomes response splitting across an HTTP/2 -> HTTP/1.1 downgrade.
#
# Offending entries are dropped and logged rather than raising: this runs on the
# response path, including the error path, where throwing would replace a real
# status with an INTERNAL and lose the original failure.

# Names the runtime owns. A handler that sets these is either mistaken or
# attempting to override the status the dispatcher determined.
const _RESERVED_RESPONSE_KEYS = Set([
    "grpc-status", "grpc-message", "grpc-status-details-bin",
    "content-type", "grpc-encoding", "grpc-accept-encoding",
])

# gRPC metadata keys are ASCII lowercase letters, digits, and `-`, `_`, `.`
# (names are lowercased on the way in by set_header!/set_trailer!).
function _valid_metadata_key(key::AbstractString)::Bool
    isempty(key) && return false
    startswith(key, ":") && return false          # pseudo-header
    for c in key
        (('a' <= c <= 'z') || ('0' <= c <= '9') || c == '-' || c == '_' || c == '.') || return false
    end
    return true
end

# RFC 9113 §8.2.1: a field value must not contain CR, LF or NUL. Base64-encoded
# `-bin` values can never trip this, so only text values are checked.
_valid_metadata_value(v::AbstractString)::Bool =
    !any(c -> c == '\r' || c == '\n' || c == '\0', v)

function _accept_response_metadata(kind::String, key::AbstractString, value)::Bool
    if key in _RESERVED_RESPONSE_KEYS
        @warn "Dropping reserved $kind set by handler" key=key
        return false
    end
    if !_valid_metadata_key(key)
        @warn "Dropping $kind with invalid name" key=key
        return false
    end
    if value isa AbstractString && !_valid_metadata_value(value)
        @warn "Dropping $kind with forbidden byte in value (CR, LF or NUL)" key=key
        return false
    end
    return true
end

"""
    get_response_headers(ctx::ServerContext) -> Vector{Tuple{String, String}}

Get response headers formatted for HTTP/2.

Handler-set names and values are validated first: reserved names, pseudo-headers,
names outside the gRPC metadata charset, and values containing CR, LF or NUL are
dropped with a warning rather than emitted.
"""
function get_response_headers(ctx::ServerContext)::Vector{Tuple{String, String}}
    headers = Tuple{String, String}[]

    for (key, value) in ctx.response_headers
        _accept_response_metadata("response header", key, value) || continue
        if value isa Vector{UInt8}
            # Binary header - base64 encode
            push!(headers, (key, base64encode(value)))
        else
            push!(headers, (key, value))
        end
    end

    return headers
end

"""
    get_response_trailers(ctx::ServerContext, status::Int, message::String) -> Vector{Tuple{String, String}}

Get response trailers formatted for HTTP/2, including gRPC status.

The runtime's own `grpc-status` / `grpc-message` are emitted first, then the
handler's trailers — validated as in [`get_response_headers`](@ref). In
particular a handler cannot append a second `grpc-status`, which would let a
client reading the last occurrence see a status the dispatcher never returned.
"""
function get_response_trailers(ctx::ServerContext, status::Int, message::String)::Vector{Tuple{String, String}}
    trailers = Tuple{String, String}[
        ("grpc-status", string(status)),
    ]

    if !isempty(message)
        # Percent-encode the message per the gRPC spec for the grpc-message header
        encoded_message = percent_encode(message)
        push!(trailers, ("grpc-message", encoded_message))
    end

    for (key, value) in ctx.trailers
        _accept_response_metadata("trailer", key, value) || continue
        if value isa Vector{UInt8}
            push!(trailers, (key, base64encode(value)))
        else
            push!(trailers, (key, value))
        end
    end

    return trailers
end

# NOTE: a second grpc-message encoder (`HTTP_urlencode`) used to live here. It
# was never called — `get_response_trailers` above uses `percent_encode`
# (src/strict.jl) — and it was wrong in two ways: it iterated over `Char` and
# applied `UInt8(c)`, so it emitted the truncated code point instead of the
# UTF-8 bytes ("café" -> "caf%E9" rather than "caf%C3%A9") and threw
# `InexactError` on any code point above U+00FF. Having a plausible-looking,
# tested-but-unused variant of a security-relevant encoder next to the real one
# is how the wrong one eventually gets wired in, so it was removed rather than
# fixed. `percent_encode` is the single implementation.

function Base.show(io::IO, ctx::ServerContext)
    print(io, "ServerContext(id=$(ctx.request_id), method=\"$(ctx.method)\"")
    if ctx.deadline !== nothing
        print(io, ", deadline=$(ctx.deadline)")
    end
    if ctx.cancelled
        print(io, ", CANCELLED")
    end
    print(io, ")")
end
