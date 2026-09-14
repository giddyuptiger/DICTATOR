// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"])
    ],
    dependencies: [
        // Parakeet on the Apple Neural Engine. Apache 2.0, runs on macOS AND iOS,
        // which is the whole reason this project can share one engine across both.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .target(
            name: "DictationCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"]
        )
    ]
)
