// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatSkill",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "WeChatSkillCore", targets: ["WeChatSkillCore"])],
    targets: [
        .target(name: "WeChatSkillCore"),
        .testTarget(name: "WeChatSkillCoreTests", dependencies: ["WeChatSkillCore"])
    ]
)
