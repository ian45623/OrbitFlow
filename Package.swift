// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OrbitFlow",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        // The dictionary is its own target so it can be tested directly: an executable
        // target cannot be imported by a test target, and the correction behaviour is
        // worth testing against fixed vectors rather than through the whole app.
        .target(
            name: "OrbitFlowDictionary",
            path: "Sources/OrbitFlowDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The rewrite tier is its own target for the same reason OrbitFlowDictionary is:
        // an executable target cannot be imported by a test target, and every decision
        // in here — the two wire dialects, the mode prompts, the output guard — is
        // logic worth testing without a network or a running app.
        .target(
            name: "OrbitFlowAIRewrite",
            path: "Sources/OrbitFlowAIRewrite",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "OrbitFlow",
            dependencies: [
                "OrbitFlowDictionary",
                "OrbitFlowAIRewrite",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/OrbitFlow",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OrbitFlowDictionaryTests",
            dependencies: ["OrbitFlowDictionary"],
            path: "Tests/OrbitFlowDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OrbitFlowAIRewriteTests",
            dependencies: ["OrbitFlowAIRewrite"],
            path: "Tests/OrbitFlowAIRewriteTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
