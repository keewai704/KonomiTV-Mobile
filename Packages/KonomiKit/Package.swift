// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KonomiKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "KonomiKit", targets: ["KonomiKit"]),
        .library(name: "KonomiStreaming", targets: ["KonomiStreaming"]),
    ],
    targets: [
        .target(name: "KonomiKit"),
        .target(name: "KonomiStreaming"),
        .testTarget(name: "KonomiKitTests", dependencies: ["KonomiKit"]),
        .testTarget(name: "KonomiStreamingTests", dependencies: ["KonomiStreaming"]),
    ],
    swiftLanguageModes: [.v6]
)
