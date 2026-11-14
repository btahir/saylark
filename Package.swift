// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Saylark",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "SaylarkApp", targets: ["SaylarkApp"]),
        .executable(name: "saylark", targets: ["SaylarkCLI"]),
        .library(name: "SaylarkCore", targets: ["SaylarkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        // Pure Swift: Fn gesture state machine, cleanup rules, dictionary, text alignment. No AppKit.
        .target(name: "SaylarkCore", swiftSettings: strict),
        // Speech: audio files and capture, voice-activity windowing, Parakeet on the Neural Engine.
        .target(
            name: "SaylarkEngine",
            dependencies: [
                "SaylarkCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: strict
        ),
        // The pill and other on-screen pieces (AppKit + Core Animation), plus the offscreen renderer.
        .target(name: "SaylarkUI", dependencies: ["SaylarkCore"], swiftSettings: strict),
        // The Mac app (menu bar). Pill Lab lives here behind a debug flag.
        .executableTarget(
            name: "SaylarkApp",
            dependencies: ["SaylarkCore", "SaylarkEngine", "SaylarkUI"],
            swiftSettings: strict
        ),
        // The `saylark` command line tool: transcribe, bench, seed.
        .executableTarget(
            name: "SaylarkCLI",
            dependencies: ["SaylarkCore", "SaylarkEngine"],
            swiftSettings: strict
        ),
        .testTarget(name: "SaylarkCoreTests", dependencies: ["SaylarkCore"], swiftSettings: strict),
        .testTarget(name: "SaylarkEngineTests", dependencies: ["SaylarkEngine"], swiftSettings: strict),
        .testTarget(name: "SaylarkUITests", dependencies: ["SaylarkUI"], swiftSettings: strict),
    ]
)
