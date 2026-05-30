# Helpers shared across the server runtime.

# Accept "application/grpc", "application/grpc+proto", "application/grpc;..." etc.
function _is_grpc_content_type(ct::AbstractString)
    ct = lowercase(strip(ct))
    return ct == "application/grpc" ||
           startswith(ct, "application/grpc+") ||
           startswith(ct, "application/grpc;")
end

"""
    parse_grpc_timeout(value) -> Int64

Parse a gRPC `grpc-timeout` header value (e.g. `"10S"`, `"500m"`, `"100u"`,
`"5n"`) and return an absolute monotonic deadline in nanoseconds (relative to
`time_ns()`). Returns `0` when no timeout is present. This is the inverse of the
client's `grpc_timeout_header_val`.
"""
function parse_grpc_timeout(value::AbstractString)::Int64
    isempty(value) && return Int64(0)
    unit = value[end]
    num = tryparse(Int64, @view value[1:end-1])
    num === nothing && throw(
        gRPCServiceCallException(GRPC_INVALID_ARGUMENT, "malformed grpc-timeout: $value"),
    )
    mult = if unit == 'H'
        3_600_000_000_000
    elseif unit == 'M'
        60_000_000_000
    elseif unit == 'S'
        1_000_000_000
    elseif unit == 'm'
        1_000_000
    elseif unit == 'u'
        1_000
    elseif unit == 'n'
        1
    else
        throw(
            gRPCServiceCallException(
                GRPC_INVALID_ARGUMENT,
                "malformed grpc-timeout unit: $value",
            ),
        )
    end
    return Int64(time_ns()) + num * mult
end

# Percent-encode a grpc-message per the gRPC spec: bytes outside printable ASCII
# (0x20..0x7E) and the '%' byte itself are escaped as %XX (uppercase hex).
function percent_encode(s::AbstractString)
    bytes = codeunits(s)
    out = IOBuffer()
    for b in bytes
        if b >= 0x20 && b <= 0x7E && b != UInt8('%')
            write(out, b)
        else
            write(out, UInt8('%'))
            write(out, uppercase(string(b, base = 16, pad = 2)))
        end
    end
    return String(take!(out))
end

# Is this exception the peer cancelling/closing the stream (RST_STREAM or
# connection close)? When true, the client is gone and there is nothing to send.
function _is_cancellation(err)
    err isa HTTP.ProtocolError && return true
    err isa EOFError && return true
    return false
end

# Spawn a task either sticky (pinned to the spawning thread, like Oxygen's
# `@async`, good for IO-bound work) or migratable (`Threads.@spawn`, enabling
# per-request multithreading for CPU-bound work). This is the single seam a
# future `serve(...; sticky=...)`-style policy flows through.
function _spawn(f; sticky::Bool = false)
    if sticky
        return @async f()
    else
        return Threads.@spawn f()
    end
end

# Wait for a pump task to finish, re-raising its original exception (not the
# wrapping TaskFailedException) so the dispatch layer can map it to a status.
function _wait_pump(t::Task)
    try
        wait(t)
    catch e
        if e isa TaskFailedException
            throw(t.result)
        else
            rethrow()
        end
    end
    return nothing
end
