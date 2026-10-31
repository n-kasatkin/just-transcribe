// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustTranscribeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JustTranscribeKit", targets: ["JustTranscribeKit"])
    ],
    targets: [
        .target(name: "JustTranscribeKit"),
        .testTarget(name: "JustTranscribeKitTests", dependencies: ["JustTranscribeKit"]),
    ]
)
