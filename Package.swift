// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "NotchWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .executableTarget(
            name: "TranscribeTest",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        )
    ]
)
