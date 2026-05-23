// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "mlx-coder",
    // SwiftPM supports Linux implicitly; `platforms` only declares Apple deployment targets.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MLXCoderCore",
            targets: ["MLXCoderCore"]
        ),
        .executable(
            name: "mlx-coder",
            targets: ["mlx-coder"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "MLXCoderCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [
                .define("SWIFTPM_NON_SANDBOX_TUI")
            ]
        ),
        .executableTarget(
            name: "mlx-coder",
            dependencies: ["MLXCoderCore"],
            swiftSettings: [
                .define("SWIFTPM_NON_SANDBOX_TUI")
            ]
        )
    ]
)
