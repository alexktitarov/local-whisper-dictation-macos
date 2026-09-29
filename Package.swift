// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalWhisper",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/LocalWhisper"
        ),
    ]
)
