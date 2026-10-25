// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SelaMemoryCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SelaMemoryCore", targets: ["SelaMemoryCore"])],
    targets: [.target(name: "SelaMemoryCore"), .testTarget(name: "SelaMemoryCoreTests", dependencies: ["SelaMemoryCore"])]
)
