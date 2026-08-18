# Adversarial tests for handler-supplied response metadata (SEC_ROADMAP phase 2e,
# finding F-004).
#
# Threat model: the handler is trusted code, but a realistic handler echoes
# client-controlled data into a response header or trailer (a request id, an
# error detail, a tenant name). These tests pin what such a handler is allowed to
# put on the wire, so the guarantee holds even when the echoed value is hostile.
#
# Everything here goes through get_response_headers / get_response_trailers,
# which every backend uses to format response metadata.

using Test
using Base64: base64encode
using gRPCServer
using gRPCServer: get_response_headers, get_response_trailers, set_header!, set_trailer!

@testset "Security: response metadata validation" begin

    # Helpers: build a context carrying one handler-set entry.
    hdrs(k, v) = (ctx = ServerContext(); set_header!(ctx, k, v); get_response_headers(ctx))
    trls(k, v) = (ctx = ServerContext(); set_trailer!(ctx, k, v);
                  get_response_trailers(ctx, Int(StatusCode.PERMISSION_DENIED), "denied"))

    @testset "A handler cannot append a second grpc-status" begin
        # The runtime pushes its own grpc-status first and the handler's entries
        # are appended, so an unfiltered duplicate would leave two grpc-status
        # fields on the wire. A client that reads the last occurrence would see
        # the handler's value — turning a real PERMISSION_DENIED into an OK.
        t = @test_logs (:warn,) match_mode = :any trls("grpc-status", "0")
        statuses = [v for (k, v) in t if k == "grpc-status"]
        @test statuses == [string(Int(StatusCode.PERMISSION_DENIED))]
        @test !("0" in statuses)
    end

    @testset "A handler cannot override grpc-message" begin
        t = @test_logs (:warn,) match_mode = :any trls("grpc-message", "spoofed")
        messages = [v for (k, v) in t if k == "grpc-message"]
        @test messages == ["denied"]
    end

    @testset "Runtime-owned names are dropped from headers too" begin
        for key in ("content-type", "grpc-encoding", "grpc-accept-encoding",
                    "grpc-status", "grpc-message", "grpc-status-details-bin")
            h = @test_logs (:warn,) match_mode = :any hdrs(key, "attacker")
            @test isempty(h)
        end
    end

    @testset "Pseudo-headers are rejected" begin
        # Illegal in a response, and HTTP/2 requires pseudo-fields to precede
        # regular ones — emitting one here is a protocol violation the peer must
        # treat as malformed.
        for key in (":path", ":status", ":authority", ":method")
            h = @test_logs (:warn,) match_mode = :any hdrs(key, "/evil")
            @test isempty(h)
        end
    end

    @testset "Names outside the gRPC metadata charset are rejected" begin
        for key in ("x space", "x\tkey", "x@key", "x/key", "x\r\nkey", "")
            h = @test_logs (:warn,) match_mode = :any hdrs(key, "v")
            @test isempty(h)
        end
    end

    @testset "CR, LF and NUL in a value are rejected" begin
        # RFC 9113 §8.2.1 forbids these outright. Over HTTP/2 alone HPACK length-
        # prefixes the value, but a CRLF that survives an HTTP/2 -> HTTP/1.1
        # downgrade at a proxy is response splitting.
        for value in ("a\r\nx-injected: 1", "a\nb", "a\rb", "a\0b")
            h = @test_logs (:warn,) match_mode = :any hdrs("x-echo", value)
            @test isempty(h)
            t = @test_logs (:warn,) match_mode = :any trls("x-echo", value)
            @test !any(k == "x-echo" for (k, _) in t)
        end
    end

    @testset "Legitimate metadata still passes through" begin
        @test hdrs("x-request-id", "abc-123") == [("x-request-id", "abc-123")]
        # set_header! lowercases, so a capitalised name is normalised, not dropped.
        @test hdrs("X-Upper-Case", "v") == [("x-upper-case", "v")]
        @test hdrs("x-dots.and_underscores-1", "v") ==
              [("x-dots.and_underscores-1", "v")]

        t = trls("x-processing-time", "150ms")
        @test ("x-processing-time", "150ms") in t
        @test ("grpc-status", string(Int(StatusCode.PERMISSION_DENIED))) in t
    end

    @testset "Binary (-bin) values are base64-encoded and never trip the byte check" begin
        # Raw CR/LF/NUL bytes are legal in a -bin value precisely because the
        # value that reaches the wire is base64, which cannot contain them.
        h = hdrs("x-blob-bin", UInt8[0x0d, 0x0a, 0x00, 0xff])
        @test length(h) == 1
        key, value = only(h)
        @test key == "x-blob-bin"
        @test !occursin('\r', value) && !occursin('\n', value) && !occursin('\0', value)
        @test value == base64encode(UInt8[0x0d, 0x0a, 0x00, 0xff])
    end
end
