// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MLXVoiceTranscriber",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "mlx-voice-transcriber",
            targets: ["MLXVoiceTranscriber"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "MLXVoiceTranscriber",
            dependencies: [
                .product(
                    name: "WhisperKit",
                    package: "argmax-oss-swift",
                    condition: .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
