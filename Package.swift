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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // Used by the Mac app target in project.yml, not by this library. It is
        // declared here so that `swift package resolve` (which Xcode Cloud's
        // post-clone script relies on) writes a Package.resolved that matches the
        // generated project's full dependency set; Xcode Cloud archives with
        // automatic resolution off and rejects a resolved file missing a package.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
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
