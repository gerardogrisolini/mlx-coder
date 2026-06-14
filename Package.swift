// swift-tools-version: 6.3

import Foundation
import PackageDescription

let localMLXEnabled: Bool = {
    #if os(macOS)
    ProcessInfo.processInfo.environment["MLX_CODER_DISABLE_LOCAL_MLX"] != "1"
    #else
    false
    #endif
}()

var products: [Product] = []

if localMLXEnabled {
    products += [
        .library(
            name: "MLXServerCore",
            targets: ["MLXServerCore"]
        ),
        .library(
            name: "MLXServerSetup",
            targets: ["MLXServerSetup"]
        )
    ]
}

products += [
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
    .library(
        name: "MLXLocalToolsSupport",
        targets: ["MLXLocalToolsSupport"]
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
    ),
    .executable(
        name: "mlx-jira-tools-feature",
        targets: ["mlx-jira-tools-feature"]
    )
]

var mlxCoderDependencies: [Target.Dependency] = [
    "MLXCoderCore",
    "MLXCoderSetup",
    "MLXPackageMetadata"
]

var mlxCoderSwiftSettings: [SwiftSetting] = [
    .define("SWIFTPM_NON_SANDBOX_TUI")
]

if localMLXEnabled {
    mlxCoderDependencies += [
        "MLXServerCore",
        "MLXServerSetup",
        .product(name: "MLXLMCommon", package: "mlx-swift-lm")
    ]
    mlxCoderSwiftSettings.append(.define("MLX_CODER_LOCAL_MLX"))
}

var targets: [Target] = [
    .target(
        name: "MLXPackageMetadata",
        dependencies: []
    ),
    .target(
        name: "MLXCoderCore",
        dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Markdown", package: "swift-markdown"),
            "MLXFeatureKit",
            "MLXLocalToolsSupport",
            "MLXPackageMetadata"
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
        dependencies: mlxCoderDependencies,
        swiftSettings: mlxCoderSwiftSettings
    ),
    .testTarget(
        name: "MLXCoderCoreTests",
        dependencies: ["MLXCoderCore"]
    ),
    .testTarget(
        name: "MLXCoderSetupTests",
        dependencies: [
            "MLXCoderCore",
            "MLXCoderSetup"
        ]
    ),
    .executableTarget(
        name: "mlx-search-tools-feature",
        dependencies: [
            "MLXFeatureKit",
            "MLXLocalToolsSupport"
        ],
        path: "Sources/Features/MLXSearchToolsFeature/Sources/mlx-search-tools-feature"
    ),
    .executableTarget(
        name: "mlx-web-tools-feature",
        dependencies: ["MLXFeatureKit"],
        path: "Sources/Features/MLXWebToolsFeature/Sources/mlx-web-tools-feature"
    ),
    .executableTarget(
        name: "mlx-git-tools-feature",
        dependencies: ["MLXFeatureKit"],
        path: "Sources/Features/MLXGitToolsFeature/Sources/mlx-git-tools-feature"
    ),
    .executableTarget(
        name: "mlx-xcode-tools-feature",
        dependencies: [
            "MLXCoderCore",
            "MLXFeatureKit"
        ],
        path: "Sources/Features/MLXXcodeToolsFeature/Sources/mlx-xcode-tools-feature"
    ),
    .executableTarget(
        name: "mlx-figma-tools-feature",
        dependencies: [
            "MLXCoderCore",
            "MLXFeatureKit"
        ],
        path: "Sources/Features/MLXFigmaToolsFeature/Sources/mlx-figma-tools-feature"
    ),
    .executableTarget(
        name: "mlx-jira-tools-feature",
        dependencies: [
            "MLXCoderCore",
            "MLXFeatureKit"
        ],
        path: "Sources/Features/MLXJiraToolsFeature/Sources/mlx-jira-tools-feature"
    )
]

if localMLXEnabled {
    targets += [
        .target(
            name: "MLXServerCore",
            dependencies: [
                "MLXPackageMetadata",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .target(
            name: "MLXServerSetup",
            dependencies: [
                "MLXServerCore",
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .testTarget(
            name: "MLXServerCoreTests",
            dependencies: ["MLXServerCore"]
        ),
        .testTarget(
            name: "MLXServerSetupTests",
            dependencies: ["MLXServerSetup"]
        )
    ]
}

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
]

if localMLXEnabled {
    dependencies += [
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main")
    ]
}

let package = Package(
    name: "mlx-coder",
    platforms: [
        .macOS(.v26)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
