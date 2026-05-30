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

        println(
            io,
            "const $(method_name) = gRPCServer.gRPCMethod{$request_type, $(rpc.request_stream), $response_type, $(rpc.response_stream)}(\"$rpc_path\")",
        )
        do_export && println(io, "export $(method_name)")
        println(io, "")
    end

    # Per-service registration convenience (the B sugar).
    register_name = "register_$(service_name)!"
    kwargs = join(["$(rpc.name)=nothing" for rpc in t.rpcs], ", ")
    println(io, "function $(register_name)(router; $kwargs)")
    for rpc in t.rpcs
        method_name = "$(service_name)_$(rpc.name)_Method"
        println(
            io,
            "\t$(rpc.name) === nothing || gRPCServer.handle!(router, $(method_name), $(rpc.name))",
        )
    end
    println(io, "\treturn router")
    println(io, "end")
    do_export && println(io, "export $(register_name)")
    println(io, "")
end

import_cb(io, ctx, definitions) =
    mapreduce(x -> x isa CodeGenerators.ServiceType ? 1 : 0, +, values(definitions); init = 0) >
    0 && println(io, "import gRPCServer")

grpc_register_service_codegen() = CodeGenerators.register_external_codegen_handler(
    "gRPCServer.jl";
    import_cb = import_cb,
    service_cb = service_cb,
)
