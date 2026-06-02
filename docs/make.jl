using Documenter
using gRPCServer

DocMeta.setdocmeta!(gRPCServer, :DocTestSetup, :(using gRPCServer); recursive = true)

makedocs(;
    modules = [gRPCServer],
    authors = "Carroll Vance <cvance@medicalmetrics.com>",
    sitename = "gRPCServer.jl",
    format = Documenter.HTML(;
        canonical = "https://JuliaIO.github.io/gRPCServer.jl",
        edit_link = "master",
        assets = String[],
    ),
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Code Generation" => "code_generation.md",
        "Handlers" => "handlers.md",
        "Concurrency" => "concurrency.md",
        "TLS" => "tls.md",
        "Performance" => "performance.md",
        "Security" => "security.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(; repo = "github.com/JuliaIO/gRPCServer.jl.git", devbranch = "master")
