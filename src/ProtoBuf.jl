# ProtoBuf.jl code-generation integration. Registered under the key
# "gRPCServer.jl" so it coexists with gRPCClient.jl's handler: a single protojl
# run with both packages loaded emits both client and server stubs.

function _resolve_type_name(ref::CodeGenerators.ReferencedType)
    name = ref.name
    if ref.package_namespace !== nothing
        name = join([ref.package_namespace, name], ".")
    end
    return name
end

function service_cb(io, t::CodeGenerators.ServiceType, ctx::CodeGenerators.Context)
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name

    do_export =
        CodeGenerators.is_namespaced(ctx.proto_file) || ctx.options.always_use_modules

    # Per-RPC descriptor constants (the C primitive).
    for rpc in t.rpcs
        rpc_path = "/$namespace.$service_name/$(rpc.name)"
        request_type = _resolve_type_name(rpc.request_type)
        response_type = _resolve_type_name(rpc.response_type)
        method_name = "$(service_name)_$(rpc.name)_Method"
        is_streaming = rpc.request_stream || rpc.response_stream

        # Streaming RPCs are unstable in gRPCServer v0.1; flag them in the
        # generated source so the limitation is visible at the call site.
        is_streaming && println(
            io,
            "# !!! WARNING: streaming RPC; unstable in gRPCServer v0.1 (known HTTP/2 lifecycle bugs). Registering it requires handle!(...; allow_unstable_streaming=true). See the Streaming docs.",
        )

        # A builder function mirroring the client's *_Client constructor.
        # TRequest / TResponse default to the generated proto types; override
        # either (or both) with Vector{UInt8} to have the handler receive the raw
        # request payload and/or return raw response bytes (partial decoding).
        println(
            io,
            "$(method_name)(; TRequest=$request_type, TResponse=$response_type) = gRPCServer.gRPCMethod{TRequest, $(rpc.request_stream), TResponse, $(rpc.response_stream)}(\"$rpc_path\")",
        )
        do_export && println(io, "export $(method_name)")
        println(io, "")
    end

    # Per-service registration convenience (the B sugar). When the service has
    # any streaming RPC, the helper takes an `allow_unstable_streaming` keyword
    # that is forwarded only to the streaming registrations (see handle!).
    register_name = "register_$(service_name)!"
    has_streaming = any(rpc -> rpc.request_stream || rpc.response_stream, t.rpcs)
    rpc_kwargs = join(["$(rpc.name)=nothing" for rpc in t.rpcs], ", ")
    signature_kwargs =
        has_streaming ? "allow_unstable_streaming=false, $rpc_kwargs" : rpc_kwargs
    println(io, "function $(register_name)(router; $signature_kwargs)")
    for rpc in t.rpcs
        method_name = "$(service_name)_$(rpc.name)_Method"
        if rpc.request_stream || rpc.response_stream
            println(
                io,
                "\t$(rpc.name) === nothing || gRPCServer.handle!(router, $(method_name)(), $(rpc.name); allow_unstable_streaming=allow_unstable_streaming)",
            )
        else
            println(
                io,
                "\t$(rpc.name) === nothing || gRPCServer.handle!(router, $(method_name)(), $(rpc.name))",
            )
        end
    end
    println(io, "\treturn router")
    println(io, "end")
    do_export && println(io, "export $(register_name)")
    println(io, "")
end

import_cb(io, ctx, definitions) =
    mapreduce(x -> x isa CodeGenerators.ServiceType ? 1 : 0, +, values(definitions); init = 0) >
    0 && println(io, "import gRPCServer")

"""
    grpc_register_service_codegen()

Register gRPCServer's external code generation handler with ProtoBuf.jl so that
a subsequent `protojl` run emits server descriptors (`<Service>_<Rpc>_Method`
builders and `register_<Service>!` helpers) for each `service` in the `.proto`.

This is called automatically from the module's `__init__`, so it normally does
not need to be invoked directly. It is exported so a host can re-register the
handler explicitly if needed.
"""
grpc_register_service_codegen() = CodeGenerators.register_external_codegen_handler(
    "gRPCServer.jl";
    import_cb = import_cb,
    service_cb = service_cb,
)
