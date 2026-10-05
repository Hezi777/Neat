// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeatKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NeatCore", targets: ["NeatCore"]),
        .library(name: "NeatAdapters", targets: ["NeatAdapters"]),
        .library(name: "NeatPipeline", targets: ["NeatPipeline"]),
        .library(name: "NeatUI", targets: ["NeatUI"]),
    ],
    dependencies: [
        // WhisperKit now ships inside Argmax's umbrella package; the old
        // argmaxinc/WhisperKit repo no longer exists. Only the WhisperKit
        // product is linked — TTSKit and SpeakerKit are not wanted.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        // No UI, no platform code. Depends on nothing.
        .target(name: "NeatCore"),

        .target(name: "NeatAdapters", dependencies: ["NeatCore"]),

        .target(
            name: "NeatPipeline",
            dependencies: [
                "NeatCore", "NeatAdapters",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]),

        .target(
            name: "NeatUI",
            dependencies: ["NeatCore", "NeatPipeline"],
            resources: [.process("Resources")]),

        .executableTarget(name: "neat-cli", dependencies: ["NeatCore", "NeatPipeline"]),

        .testTarget(name: "NeatCoreTests", dependencies: ["NeatCore"]),
        .testTarget(name: "NeatAdaptersTests", dependencies: ["NeatAdapters"]),
        .testTarget(name: "NeatPipelineTests", dependencies: ["NeatPipeline"]),
    ]
)
