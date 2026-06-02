# TLS

The server speaks cleartext HTTP/2 (h2c) by default. To serve HTTP/2 over TLS
(h2), pass `tls = true` with a certificate and key:

```julia
serve!(router, "0.0.0.0", 443;
    tls = true, cert_file = "cert.pem", key_file = "key.pem")
```

Cleartext h2c should only be used behind a trusted boundary, for example a
localhost sidecar or a TLS-terminating proxy. For production deployments that
face untrusted networks, use TLS. See [Security](security.md) for the broader
deployment guidance, including the fact that the server does not perform mutual
TLS or client-certificate verification.
