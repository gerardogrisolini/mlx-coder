// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "mlx-server",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "MLXServerCore",
            targets: ["MLXServerCore"]
        ),
        .library(
            name: "MLXServerHTTP",
            targets: ["MLXServerHTTP"]
        ),
        .library(
            name: "MLXServerSetup",
            targets: ["MLXServerSetup"]
        ),
        .executable(
            name: "mlx-server",
            targets: ["mlx-server"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.39.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main")
    ],
    targets: [
        .target(
            name: "MLXServerCore",
            dependencies: [
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "mlx-server",
            dependencies: [
                "MLXServerCore",
                "MLXServerHTTP",
                "MLXServerSetup",
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .target(
            name: "MLXServerSetup",
            dependencies: [
                "MLXServerCore",
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .target(
            name: "MLXServerHTTP",
            dependencies: [
                "MLXServerCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
        .testTarget(
            name: "MLXServerCoreTests",
            dependencies: ["MLXServerCore"]
        ),
        .testTarget(
            name: "MLXServerHTTPTests",
            dependencies: [
                "MLXServerCore",
                "MLXServerHTTP"
            ]
        )
    ]
)
