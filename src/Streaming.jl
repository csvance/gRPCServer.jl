# Server-streaming and bidirectional invocation, plus the channel pump tasks.

# Decode inbound frames into the request channel until half-close, then close it.
function _feed_requests(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    in::Channel{TReq},
    ::Type{TReq},
    router::gRPCRouter,
) where {TReq}
    fr = FrameReader(stream, router.max_recieve_message_length)
    try
        while true
            io = read_message!(fr)
            io === nothing && break
            put!(in, decode(ProtoDecoder(io), TReq))
        end
    catch err
        if _is_cancellation(err)
            ctx.cancelled[] = true
        else
            rethrow(err)
        end
    finally
        close(in)
    end
    return nothing
end

# Drain responses from the output channel, frame-encode each, and write to the
# stream. HTTP.jl applies HTTP/2 flow-control backpressure on write.
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
            write(stream, take!(encode_buf))
        end
    catch err
        if _is_cancellation(err)
            ctx.cancelled[] = true
        else
            rethrow(err)
        end
    end
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
    fr = FrameReader(stream, router.max_recieve_message_length)
    io = read_message!(fr)
    io === nothing && throw(
        gRPCServiceCallException(GRPC_INVALID_ARGUMENT, "server-stream request missing message"),
    )
    req = decode(ProtoDecoder(io), TReq)
    expect_half_close!(fr)

    out = Channel{TResp}(16)
    _start_response!(stream, ctx)
    pump = _spawn(sticky = ctx.sticky) do
        _drain_responses(stream, ctx, out, router)
    end

    try
        fn(req, out, ctx)
    finally
        close(out)
    end
    _wait_pump(pump)
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

    _start_response!(stream, ctx)
    feeder = _spawn(sticky = ctx.sticky) do
        _feed_requests(stream, ctx, in, TReq, router)
    end
    pump = _spawn(sticky = ctx.sticky) do
        _drain_responses(stream, ctx, out, router)
    end

    try
        fn(in, out, ctx)
    finally
        close(out)
    end
    _wait_pump(feeder)
    _wait_pump(pump)
    return nothing
end
