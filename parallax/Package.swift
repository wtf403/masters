// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parallax",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "ParallaxKit", targets: ["ParallaxKit"]),
        .library(name: "ParallaxApp", targets: ["ParallaxApp"]),
        .executable(name: "parallax-package-clip", targets: ["PackageClip"]),
        .executable(name: "parallax-build-depth", targets: ["BuildDepth"]),
    ],
    targets: [
        .target(name: "ParallaxKit", path: "Sources/ParallaxKit"),
        .target(name: "ParallaxApp", dependencies: ["ParallaxKit"], path: "Sources/ParallaxApp"),
        .executableTarget(name: "PackageClip", dependencies: ["ParallaxKit"], path: "Tools/PackageClip"),
        .executableTarget(name: "BuildDepth", dependencies: ["ParallaxKit"], path: "Tools/BuildDepth"),
        .testTarget(name: "ParallaxKitTests", dependencies: ["ParallaxKit"], path: "Tests/ParallaxKitTests"),
    ]
)

