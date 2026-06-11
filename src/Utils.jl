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

The grpc spec constrains the value to 1-8 ASCII digits followed by a unit
character. We enforce that (rejecting empty, over-long, signed, or non-numeric
values) and use checked arithmetic so a hostile or absurd value yields a clean
`INVALID_ARGUMENT` rather than a silently wrapped, garbage deadline.
"""
function parse_grpc_timeout(value::AbstractString)::Int64
    # Operate on raw code units, not string indices: HTTP/2 header values are
    # arbitrary octets, and indexing a String whose bytes are not valid UTF-8
    # throws StringIndexError instead of yielding the clean INVALID_ARGUMENT
    # below. The spec grammar is ASCII-only, so byte-wise parsing is exact.
    cu = codeunits(value)
    isempty(cu) && return Int64(0)
    unit = Char(cu[end])
    ndigits = length(cu) - 1
    # Spec: TimeoutValue is 1-8 ASCII digits, no sign; the byte range check
    # also rejects '-', '+', and whitespace.
    if ndigits < 1 || ndigits > 8 || !all(b -> UInt8('0') <= b <= UInt8('9'), @view cu[1:ndigits])
        throw(
            gRPCServiceCallException(GRPC_INVALID_ARGUMENT, "malformed grpc-timeout: $(_clip(value))"),
        )
    end
    num = Int64(0)
    for i = 1:ndigits
        num = num * 10 + Int64(cu[i] - UInt8('0'))  # <= 8 digits always fits in Int64
    end
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
                "malformed grpc-timeout unit: $(_clip(value))",
            ),
        )
    end
    try
        return Base.Checked.checked_add(Int64(time_ns()), Base.Checked.checked_mul(num, Int64(mult)))
    catch err
        err isa OverflowError && throw(
            gRPCServiceCallException(GRPC_INVALID_ARGUMENT, "grpc-timeout out of range: $(_clip(value))"),
        )
        rethrow()
    end
end

# Truncate client-supplied text before echoing it back in an error message, so a
# hostile peer cannot inflate a `grpc-message` trailer with an arbitrarily long
# reflection of its own input.
function _clip(s::AbstractString, n::Int = 128)
    return length(s) > n ? string(first(s, n), "...") : String(s)
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
