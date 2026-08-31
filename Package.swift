// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TheScorePrototype",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScoreCore", targets: ["ScoreCore"]),
        .library(name: "ScoreAudioEngine", targets: ["ScoreAudioEngine"]),
        .executable(name: "ScoreLab", targets: ["ScoreLab"]),
    ],
    targets: [
        .target(
            name: "ScoreCore"
        ),
        .target(
            name: "ScoreAudioEngine",
            dependencies: ["ScoreCore"],
            resources: [
                .copy("Resources/EngineeringScore"),
            ]
        ),
        .executableTarget(
            name: "ScoreLab",
            dependencies: ["ScoreCore", "ScoreAudioEngine"]
        ),
        .testTarget(
            name: "ScoreCoreTests",
            dependencies: ["ScoreCore"]
        ),
        .testTarget(
            name: "ScoreAudioEngineTests",
            dependencies: ["ScoreAudioEngine", "ScoreCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
