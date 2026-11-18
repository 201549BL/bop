// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BopCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BopCore", targets: ["BopCore"])],
    targets: [
        .target(name: "BopCore"),
        .testTarget(name: "BopCoreTests", dependencies: ["BopCore"])
    ]
)
