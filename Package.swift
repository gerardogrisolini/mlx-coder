// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "mlx-server",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
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
        .library(
            name: "MLXCoderCore",
            targets: ["MLXCoderCore"]
        ),
        .library(
            name: "MLXCoderSetup",
            targets: ["MLXCoderSetup"]
        ),
        .library(
            name: "MLXFeatureKit",
            targets: ["MLXFeatureKit"]
        ),
        .executable(
            name: "mlx-server",
            targets: ["mlx-server"]
        ),
        .executable(
            name: "mlx-coder",
            targets: ["mlx-coder"]
        ),
        .executable(
            name: "mlx-search-tools-feature",
            targets: ["mlx-search-tools-feature"]
        ),
        .executable(
            name: "mlx-web-tools-feature",
            targets: ["mlx-web-tools-feature"]
        ),
        .executable(
            name: "mlx-git-tools-feature",
            targets: ["mlx-git-tools-feature"]
        ),
        .executable(
            name: "mlx-xcode-tools-feature",
            targets: ["mlx-xcode-tools-feature"]
        ),
        .executable(
            name: "mlx-figma-tools-feature",
            targets: ["mlx-figma-tools-feature"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.39.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "MLXServerCore",
            dependencies: [
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
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
                "MLXCoderCore",
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .target(
            name: "MLXCoderCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Markdown", package: "swift-markdown"),
                "MLXFeatureKit",
                "MLXLocalToolsSupport"
            ],
            swiftSettings: [
                .define("SWIFTPM_NON_SANDBOX_TUI")
            ]
        ),
        .target(
            name: "MLXFeatureKit",
            dependencies: []
        ),
        .target(
            name: "MLXLocalToolsSupport",
            dependencies: ["MLXFeatureKit"]
        ),
        .target(
            name: "MLXCoderSetup",
            dependencies: ["MLXCoderCore"],
            swiftSettings: [
                .define("SWIFTPM_NON_SANDBOX_TUI")
            ]
        ),
        .executableTarget(
            name: "mlx-coder",
            dependencies: [
                "MLXCoderCore",
                "MLXCoderSetup"
            ],
            swiftSettings: [
                .define("SWIFTPM_NON_SANDBOX_TUI")
            ]
        ),
        .executableTarget(
            name: "mlx-search-tools-feature",
            dependencies: [
                "MLXFeatureKit",
                "MLXLocalToolsSupport"
            ],
            path: "Features/MLXSearchToolsFeature"
        ),
        .executableTarget(
            name: "mlx-web-tools-feature",
            dependencies: ["MLXFeatureKit"],
            path: "Features/MLXWebToolsFeature"
        ),
        .executableTarget(
            name: "mlx-git-tools-feature",
            dependencies: ["MLXFeatureKit"],
            path: "Features/MLXGitToolsFeature"
        ),
        .executableTarget(
            name: "mlx-xcode-tools-feature",
            dependencies: [
                "MLXCoderCore",
                "MLXFeatureKit"
            ],
            path: "Features/MLXXcodeToolsFeature"
        ),
        .executableTarget(
            name: "mlx-figma-tools-feature",
            dependencies: [
                "MLXCoderCore",
                "MLXFeatureKit"
            ],
            path: "Features/MLXFigmaToolsFeature"
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
            name: "MLXServerSetupTests",
            dependencies: ["MLXServerSetup"]
        ),
        .testTarget(
            name: "MLXServerHTTPTests",
            dependencies: [
                "MLXServerCore",
                "MLXServerHTTP"
            ]
        ),
        .testTarget(
            name: "MLXCoderCoreTests",
            dependencies: ["MLXCoderCore"]
        )
    ]
)
