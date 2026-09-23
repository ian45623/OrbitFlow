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
            dependencies: ["OrbitFlowModels"],
            path: "Sources/OrbitFlowAIRewrite",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The shortcut-key list is its own target so resolve/add/remove can be tested
        // without the app target. An executable cannot be imported by tests.
        .target(
            name: "OrbitFlowHotkey",
            path: "Sources/OrbitFlowHotkey",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The week's statistics are their own target for the same reason the dictionary is:
        // a median, a share and a word count are worth testing against fixed samples, and
        // an executable target cannot be imported by a test target.
        .target(
            name: "OrbitFlowStats",
            path: "Sources/OrbitFlowStats",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Sessions and filters: "ten minutes continues a session, eleven starts a new one"
        // is a decision worth pinning with a test rather than rediscovering from a screen.
        .target(
            name: "OrbitFlowHistory",
            path: "Sources/OrbitFlowHistory",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Grades and the readout are real logic — a mean, a rounding, and a rule about
        // when anything leaves the Mac — and an executable target cannot be imported by
        // a test target. Same reason OrbitFlowStats exists.
        .target(
            name: "OrbitFlowModels",
            path: "Sources/OrbitFlowModels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // What to set the system volume to while the microphone is open, and whether to put
        // it back: "the user moved the slider mid-dictation, so leave it" is a rule worth a
        // test, and the CoreAudio calls that act on it can't run under one.
        .target(
            name: "OrbitFlowAudio",
            path: "Sources/OrbitFlowAudio",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "OrbitFlow",
            dependencies: [
                "OrbitFlowDictionary",
                "OrbitFlowAIRewrite",
                "OrbitFlowHotkey",
                "OrbitFlowStats",
                "OrbitFlowHistory",
                "OrbitFlowModels",
                "OrbitFlowAudio",
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
            dependencies: ["OrbitFlowAIRewrite", "OrbitFlowModels"],
            path: "Tests/OrbitFlowAIRewriteTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OrbitFlowHotkeyTests",
            dependencies: ["OrbitFlowHotkey"],
            path: "Tests/OrbitFlowHotkeyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OrbitFlowHistoryTests",
            dependencies: ["OrbitFlowHistory"],
            path: "Tests/OrbitFlowHistoryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OrbitFlowStatsTests",
            dependencies: ["OrbitFlowStats"],
            path: "Tests/OrbitFlowStatsTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OrbitFlowModelsTests",
            dependencies: ["OrbitFlowModels"],
            path: "Tests/OrbitFlowModelsTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OrbitFlowAudioTests",
            dependencies: ["OrbitFlowAudio"],
            path: "Tests/OrbitFlowAudioTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
