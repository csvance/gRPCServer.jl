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
function _invoke_client_stream(
    stream::HTTP.Stream,
    ctx::gRPCContext,
    m::gRPCMethod{TReq,true,TResp,false},
    fn,
    router::gRPCRouter,
) where {TReq,TResp}
    in = Channel{TReq}(16)
    feeder = _spawn(sticky = ctx.sticky) do
        _feed_requests(stream, ctx, in, TReq, router)
    end

    resp = fn(in, ctx)::TResp
    _wait_pump(feeder)

    _start_response!(stream, ctx)
    out = grpc_encode_message_iobuffer(
        resp;
        max_send_message_length = router.max_send_message_length,
    )
    write(stream, take!(out))
    return nothing
end
