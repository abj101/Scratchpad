// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanvasKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CanvasKit", targets: ["CanvasKit"]),
    ],
    targets: [
        .target(name: "CanvasKit", path: "Sources/CanvasKit", resources: [
            .copy("Resources/HersheyGlyphs.json"),
            .copy("Resources/HERSHEY-NOTICE.txt"),
            .copy("Resources/RELIEF_NOTICE.md"),
            .copy("Resources/ReliefSingleLine-OFL.txt"),
            .copy("Resources/MathGlyphs.mlmodelc"),
            .copy("Resources/MathGlyphs-manifest.json"),
            .copy("Resources/vocab.json"),
            .copy("Resources/math-vocab.json"),
            .copy("Resources/MathLM.json"),
            .copy("Resources/MathLive"),
        ]),
        .testTarget(name: "CanvasKitTests", dependencies: ["CanvasKit"], path: "Tests/CanvasKitTests",
                    resources: [.copy("Fixtures/raster"), .copy("Fixtures/native-parity.json"),
                                .copy("Fixtures/sequence"), .copy("Fixtures/resolver"), .copy("Fixtures/lm"), .copy("Fixtures/decoder")]),
    ]
)
