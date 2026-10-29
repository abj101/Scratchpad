// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackpadSpike",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TrackpadSpike",
            path: "Sources/TrackpadSpike"
        )
    ]
)
