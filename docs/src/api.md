# API Reference

This page documents the full public interface of gRPCServer.jl.

```@meta
CurrentModule = gRPCServer
```

## Types

```@docs
gRPCRouter
gRPCMethod
gRPCContext
```

## Serving

```@docs
serve!
serve
```

## Handler registration

```@docs
handle!
```

## Context

```@docs
metadata
set_initial_metadata!
set_trailing_metadata!
```

## Deadlines and cancellation

```@docs
deadline_exceeded
iscancelled
```

## Errors

```@docs
gRPCException
gRPCServiceCallException
```

## Status codes

```@docs
GRPC_OK
GRPC_CANCELLED
GRPC_UNKNOWN
GRPC_INVALID_ARGUMENT
GRPC_DEADLINE_EXCEEDED
GRPC_NOT_FOUND
GRPC_ALREADY_EXISTS
GRPC_PERMISSION_DENIED
GRPC_RESOURCE_EXHAUSTED
GRPC_FAILED_PRECONDITION
GRPC_ABORTED
GRPC_OUT_OF_RANGE
GRPC_UNIMPLEMENTED
GRPC_INTERNAL
GRPC_UNAVAILABLE
GRPC_DATA_LOSS
GRPC_UNAUTHENTICATED
GRPC_CODE_TABLE
```

## Code generation

```@docs
grpc_register_service_codegen
```
