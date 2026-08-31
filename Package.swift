// swift-tools-version:5.10
import PackageDescription

// Linker + rpath flags for the vendored llama.cpp / mtmd libraries
// (vendor/llama/lib, populated by scripts/fetch_llama.sh).
//   · -L …/lib             resolve -lmtmd / -lllama at link time
//   · rpath …/Frameworks   the packaged .app (build.sh copies the dylibs there)
//   · rpath …/vendor/llama/lib (a couple of depths) — `swift run` in-tree dev
let llamaLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", "vendor/llama/lib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../vendor/llama/lib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/llama/lib",
    ]),
]

let package = Package(
    name: "NotchWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", branch: "main"),
    ],
    targets: [
        // C interop for the vendored llama.cpp + mtmd headers.
        .target(
            name: "CLlama",
            path: "vendor/llama",
            exclude: ["lib", "LICENSE-llama.cpp", "BUILD.txt"],
            sources: ["shim.c"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "NotchWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "CLlama",
            ],
            linkerSettings: llamaLinkerSettings
        ),
        .executableTarget(
            name: "TranscribeTest",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .executableTarget(
            name: "LiveRepro",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        )
    ]
)
