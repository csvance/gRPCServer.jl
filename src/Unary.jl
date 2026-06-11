# Unary and client-streaming invocation. These run on the per-stream handler
# task that HTTP.jl spawns; they are type-stable because `m` is concrete.

# Unary: fn(req::TReq, ctx) -> TResp
function _invoke_unary(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    m::gRPCMethod{TReq,false,TResp,false},
    fn,
    router::gRPCRouter,
) where {TReq,TResp}
    fr = FrameReader(stream, router.max_receive_message_length)
    io = read_message!(fr)
    io === nothing &&
        throw(gRPCServiceCallException(GRPC_INVALID_ARGUMENT, "unary request missing message"))
    req = _decode_request(io, TReq)
    expect_half_close!(fr)

    resp = fn(req, ctx)::TResp

    _start_response!(stream, ctx)
    out = grpc_encode_message_iobuffer(
        resp;
        max_send_message_length = router.max_send_message_length,
    )
    write(stream, take!(out))
    return nothing
end

# Client streaming: fn(in::Channel{TReq}, ctx) -> TResp
#
# The feeder task is never joined (see the shutdown protocol note in
# Streaming.jl): the invoker closes `in` once the handler is done, which stops
# the feeder, and reads its recorded outcome. A handler may legally return
# before the client half-closes; the rest of the request stream is abandoned.
function _invoke_client_stream(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    m::gRPCMethod{TReq,true,TResp,false},
    fn,
    router::gRPCRouter,
) where {TReq,TResp}
    in = Channel{TReq}(16)
    outcome = _FeederOutcome(nothing)
    _spawn(sticky = ctx.sticky) do
        _feed_requests(stream, ctx, in, TReq, router, outcome)
    end

    local resp
    try
        resp = fn(in, ctx)::TResp
    finally
        close(in)
    end
    _check_feeder!(outcome)

    _start_response!(stream, ctx)
    out = grpc_encode_message_iobuffer(
        resp;
        max_send_message_length = router.max_send_message_length,
    )
    write(stream, take!(out))
    return nothing
end
