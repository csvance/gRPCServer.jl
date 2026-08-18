# Adversarial TLS configuration tests (SEC_ROADMAP phase 2d).
#
# These cover the configuration and listener-construction surface — the part that
# decides whether a server comes up at all, and with what guarantees. Handshake
# behaviour against a hostile client is covered by the interop suite.
#
# Two of these tests pin behaviour that is *currently wrong* (finding F-002:
# invalid key material is accepted at construction). They are marked @test_broken
# so the suite stays green while making the gap impossible to forget — when the
# upstream question is settled they will flip to failing-as-broken and must be
# converted to real assertions.

using Test
using gRPCServer
using gRPCServer: TLSConfig, TLSTransport, TLSHandshakeError, TLSHandshakeFailureKind

const CERT_DIR_SEC = joinpath(@__DIR__, "..", "fixtures", "certs")
const HAVE_CERTS = isfile(joinpath(CERT_DIR_SEC, "server.crt"))

@testset "Security: TLS configuration" begin

    @testset "TLSConfig rejects incoherent configuration" begin
        # mTLS without a CA cannot verify anything; accepting it would give a
        # server that looks mutually authenticated and is not.
        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem", require_client_cert = true)

        # An unknown minimum version must not silently fall back to a weaker one.
        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem", min_version = :TLSv1_0)
        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem", min_version = :SSLv3)

        # An empty ALPN list would negotiate nothing at all.
        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem", alpn_protocols = String[])

        # ALPN entries are length-prefixed with a single byte on the wire.
        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem", alpn_protocols = [""])
        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem",
            alpn_protocols = ["h2", "x"^256])

        @test_throws ArgumentError TLSConfig(
            cert_chain = "c.pem", private_key = "k.pem", handshake_timeout_ns = -1)
    end

    @testset "TLSConfig defends its own state" begin
        # The ALPN list is copied, so a caller mutating the vector afterwards
        # cannot change what an already-built config negotiates.
        alpn = ["h2"]
        cfg = TLSConfig(cert_chain = "c.pem", private_key = "k.pem", alpn_protocols = alpn)
        push!(alpn, "http/1.1")
        @test cfg.alpn_protocols == ["h2"]
    end

    @testset "Missing key material is refused at construction" begin
        dir = mktempdir()
        cert = joinpath(dir, "server.crt")
        key = joinpath(dir, "server.key")
        write(cert, "x")
        write(key, "x")

        # Each missing file is reported as a CONFIG_ERROR, not as a bind failure
        # or an opaque UndefVarError (finding F-001).
        for cfg in (
            TLSConfig(cert_chain = joinpath(dir, "absent.crt"), private_key = key),
            TLSConfig(cert_chain = cert, private_key = joinpath(dir, "absent.key")),
            TLSConfig(cert_chain = cert, private_key = key,
                      client_ca = joinpath(dir, "absent-ca.crt")),
        )
            err = try
                TLSTransport(cfg, "127.0.0.1", 0)
                nothing
            catch e
                e
            end
            @test err isa TLSHandshakeError
            @test err.kind === TLSHandshakeFailureKind.CONFIG_ERROR
        end
    end

    if HAVE_CERTS
        @testset "A failed bind reports CONFIG_ERROR with a usable message" begin
            # Regression test for F-001: this branch threw an unqualified
            # `CONFIG_ERROR`, so it raised UndefVarError and destroyed the
            # diagnostic. Real key material is required to reach it — the
            # structural PEM check now rejects placeholder files earlier.
            cfg = TLSConfig(cert_chain = joinpath(CERT_DIR_SEC, "server.crt"),
                            private_key = joinpath(CERT_DIR_SEC, "server.key"))

            # 192.0.2.0/24 is TEST-NET-1: never assigned to a local interface.
            err = try
                TLSTransport(cfg, "192.0.2.1", 443)
                nothing
            catch e
                e
            end
            @test err isa TLSHandshakeError
            @test err.kind === TLSHandshakeFailureKind.CONFIG_ERROR
            @test occursin("Failed to bind TLS listener", err.message)
            @test err.cause !== nothing
        end
    end

    @testset "Malformed key material is refused at construction (F-002)" begin
        # Reseau parses key material lazily, at first handshake. Without a check
        # here a server with a corrupt certificate would start up reporting
        # success and then fail every handshake, client by client — the failure
        # surfacing in production rather than at startup.
        #
        # The check is structural, not cryptographic: it does not verify that the
        # key matches the certificate or that nothing has expired (Reseau still
        # decides that at handshake time). It catches the operational mistake.
        dir = mktempdir()
        mk(name, content) = (p = joinpath(dir, name); write(p, content); p)
        real_cert = joinpath(CERT_DIR_SEC, "server.crt")
        real_key = joinpath(CERT_DIR_SEC, "server.key")

        function build(cert, key; ca = nothing)
            cfg = TLSConfig(cert_chain = cert, private_key = key, client_ca = ca,
                            require_client_cert = ca !== nothing)
            try
                t = TLSTransport(cfg, "127.0.0.1", 0)
                close(t)
                return nothing
            catch e
                return e
            end
        end

        if HAVE_CERTS
            cases = [
                ("garbage certificate", mk("bad.crt", "not a pem"), real_key),
                ("garbage key", real_cert, mk("bad.key", "not a pem")),
                ("empty certificate", mk("empty.crt", ""), real_key),
                # BEGIN with no matching END: the truncated-file case.
                ("truncated certificate",
                 mk("trunc.crt", first(read(real_cert, String), 120)), real_key),
                # A real PEM, but the wrong kind in the wrong slot.
                ("certificate and key swapped", real_key, real_cert),
            ]
            for (name, cert, key) in cases
                err = build(cert, key)
                @test err isa TLSHandshakeError
                @test err.kind === TLSHandshakeFailureKind.CONFIG_ERROR
                # The private key's *contents* must never be echoed into an error.
                @test !occursin("PRIVATE KEY-----", err.message)
            end

            @test build(real_cert, real_key; ca = mk("bad.ca", "nope")) isa TLSHandshakeError

            # Valid material is unaffected, with and without mTLS.
            @test build(real_cert, real_key) === nothing
            @test build(real_cert, real_key; ca = joinpath(CERT_DIR_SEC, "ca.crt")) === nothing
        end
    end

    if HAVE_CERTS
        @testset "reload! with invalid material leaves the transport untouched (F-002)" begin
            # The documented invariant: "leaves the transport untouched if
            # new_config cannot be built". Before the structural check this held
            # only for a *missing* file — a present-but-corrupt one was installed
            # and reported as success, so a certificate rotation could take the
            # server down at the next handshake.
            dir = mktempdir()
            good = TLSConfig(cert_chain = joinpath(CERT_DIR_SEC, "server.crt"),
                             private_key = joinpath(CERT_DIR_SEC, "server.key"))
            t = TLSTransport(good, "127.0.0.1", 0)

            corrupt = joinpath(dir, "rotated.crt"); write(corrupt, "not a pem")
            bad = TLSConfig(cert_chain = corrupt,
                            private_key = joinpath(CERT_DIR_SEC, "server.key"))

            @test_throws TLSHandshakeError gRPCServer.reload!(t, bad)
            @test t.grpc_config === good     # untouched
            @test isopen(t)

            # And a genuine rotation still works.
            @test gRPCServer.reload!(t, good) === nothing
            @test isopen(t)
            close(t)
        end
    end

    if HAVE_CERTS
        @testset "Real key material builds a listener and closes cleanly" begin
            cfg = TLSConfig(cert_chain = joinpath(CERT_DIR_SEC, "server.crt"),
                            private_key = joinpath(CERT_DIR_SEC, "server.key"))
            t = TLSTransport(cfg, "127.0.0.1", 0)
            @test isopen(t)
            close(t)
            @test !isopen(t)
            close(t)  # idempotent
        end

        @testset "mTLS configuration is carried through to the transport" begin
            cfg = TLSConfig(
                cert_chain = joinpath(CERT_DIR_SEC, "server.crt"),
                private_key = joinpath(CERT_DIR_SEC, "server.key"),
                client_ca = joinpath(CERT_DIR_SEC, "ca.crt"),
                require_client_cert = true,
                min_version = :TLSv1_3,
            )
            t = TLSTransport(cfg, "127.0.0.1", 0)
            @test t.grpc_config.require_client_cert
            @test t.grpc_config.client_ca == joinpath(CERT_DIR_SEC, "ca.crt")
            @test t.grpc_config.min_version === :TLSv1_3
            close(t)
        end

        @testset "reload! with missing material leaves the transport untouched" begin
            good = TLSConfig(cert_chain = joinpath(CERT_DIR_SEC, "server.crt"),
                             private_key = joinpath(CERT_DIR_SEC, "server.key"))
            t = TLSTransport(good, "127.0.0.1", 0)
            bad = TLSConfig(cert_chain = joinpath(mktempdir(), "absent.crt"),
                            private_key = joinpath(CERT_DIR_SEC, "server.key"))

            @test_throws TLSHandshakeError gRPCServer.reload!(t, bad)
            # The invariant holds for a *missing* file; F-002 is that it does not
            # hold for a present-but-invalid one.
            @test t.grpc_config === good
            @test isopen(t)
            close(t)
        end
    end
end
