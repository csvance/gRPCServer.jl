# Server-streaming and bidirectional invocation, plus the channel pump tasks.
#
# Shutdown protocol. Each invoker owns the lifecycle of its pump tasks:
#
#   - The response pump (`_drain_responses`) writes to the HTTP stream, so it is
#     always joined before the invoker returns or rethrows; otherwise it could
#     race the trailer write in `dispatch`. It is guaranteed to terminate once
#     `out` is closed: it drains the buffered messages and exits, and on a write
#     or encode failure it closes `out` with that exception so a producer
#     blocked in `put!` is released rather than stranded.
#
#   - The request feeder (`_feed_requests`) only reads, so it is never joined.
#     Joining it could block forever: when a handler completes before the client
#     half-closes, the feeder may be parked in a stream read that finishes only
#     when the peer sends more data. Instead the invoker closes `in` (making any
#     pending `put!` throw, which the feeder treats as a graceful stop) and
#     reports the feeder's outcome through `_FeederOutcome`, an atomic slot the
#     feeder fills before closing `in`. `HTTP.closeread` in `dispatch`'s
#     `finally` then aborts the read side, after the trailers are on the wire,
#     and a parked feeder read returns EOF.

# Filled by the feeder before it closes `in`, read by the invoker after the
# handler returns. Closing `in` happens-after the store, and the handler only
# observes the closed channel after that, so the invoker's read is ordered; the
# atomic covers the handler-completes-early case where the feeder is still live.
mutable struct _FeederOutcome
    @atomic err::Union{Nothing,Exception}
end

# Decode inbound frames into the request channel until half-close, then close it.
# A malformed or oversize frame is recorded in `outcome` (not thrown): the
# invoker raises it after the handler returns, so it reaches the client as the
# RPC status. A `put!` on a channel the invoker closed means the handler
# completed early; the rest of the request stream is abandoned, which is a legal
# gRPC completion.
function _feed_requests(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    in::Channel{TReq},
    ::Type{TReq},
    router::gRPCRouter,
    outcome::_FeederOutcome,
) where {TReq}
    fr = FrameReader(stream, router.max_receive_message_length)
    try
        while true
            io = read_message!(fr)
            io === nothing && break
            put!(in, _decode_request(io, TReq))
        end
    catch err
        if _is_cancellation(err)
            ctx.cancelled[] = true
        elseif isopen(in)
            @atomic outcome.err = err
        end
    finally
        close(in)
    end
    return nothing
end

# Drain responses from the output channel, frame-encode each, and write to the
# stream. HTTP.jl applies HTTP/2 flow-control backpressure on write. The
# response head is sent lazily before the first message so a streaming handler
# can still set initial metadata; `_finish_ok`/`_finish_error` send it for the
# zero-message case.
function _drain_responses(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    out::Channel{TResp},
    router::gRPCRouter,
) where {TResp}
    encode_buf = IOBuffer()
    try
        for resp in out
            grpc_encode_message_iobuffer(
                resp,
                encode_buf;
                max_send_message_length = router.max_send_message_length,
            )
            _start_response!(stream, ctx)
            write(stream, take!(encode_buf))
        end
    catch err
        _is_cancellation(err) && (ctx.cancelled[] = true)
        # Release any producer blocked in put!: it rethrows `err`, so an encode
        # failure surfaces as its gRPC status and a peer reset as a cancellation.
        close(out, err)
        rethrow(err)
    end
    return nothing
end

# Shut down after the handler finished: stop the pumps and join the response
# pump so it cannot race the trailer write. When the handler itself failed, its
# exception is already propagating, so a pump failure is dropped here (it is
# usually the same exception, delivered to the handler through a closed
# channel); otherwise the pump failure propagates to set the RPC status.
function _shutdown_pumps!(in::Union{Nothing,Channel}, out::Channel, pump::Task, handler_failed::Bool)
    close(out)
    in === nothing || close(in)
    if handler_failed
        try
            _wait_pump(pump)
        catch
        end
    else
        _wait_pump(pump)
    end
    return nothing
end

# Raise the request-stream error the feeder recorded, if any (oversize frame,
# malformed framing). Cancellations are not recorded: they surface when the
# response write fails.
function _check_feeder!(outcome::_FeederOutcome)
    err = @atomic outcome.err
    err === nothing || throw(err)
    return nothing
end

# Server streaming: fn(req::TReq, out::Channel{TResp}, ctx)
function _invoke_server_stream(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    m::gRPCMethod{TReq,false,TResp,true},
    fn,
    router::gRPCRouter,
) where {TReq,TResp}
    fr = FrameReader(stream, router.max_receive_message_length)
    io = read_message!(fr)
    io === nothing && throw(
        gRPCServiceCallException(GRPC_INVALID_ARGUMENT, "server-stream request missing message"),
    )
    req = _decode_request(io, TReq)
    expect_half_close!(fr)

    out = Channel{TResp}(16)
    pump = _spawn(sticky = ctx.sticky) do
        _drain_responses(stream, ctx, out, router)
    end

    handler_failed = false
    try
        fn(req, out, ctx)
    catch
        handler_failed = true
        rethrow()
    finally
        _shutdown_pumps!(nothing, out, pump, handler_failed)
    end
    return nothing
end

# Bidirectional streaming: fn(in::Channel{TReq}, out::Channel{TResp}, ctx)
function _invoke_bidi(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    m::gRPCMethod{TReq,true,TResp,true},
    fn,
    router::gRPCRouter,
) where {TReq,TResp}
    in = Channel{TReq}(16)
    out = Channel{TResp}(16)
    outcome = _FeederOutcome(nothing)

    _spawn(sticky = ctx.sticky) do
        _feed_requests(stream, ctx, in, TReq, router, outcome)
    end
    pump = _spawn(sticky = ctx.sticky) do
        _drain_responses(stream, ctx, out, router)
    end

    handler_failed = false
    try
        fn(in, out, ctx)
    catch
        handler_failed = true
        rethrow()
    finally
        _shutdown_pumps!(in, out, pump, handler_failed)
    end
    _check_feeder!(outcome)
    return nothing
end
