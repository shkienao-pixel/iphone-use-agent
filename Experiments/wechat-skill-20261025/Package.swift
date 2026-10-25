// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatSkill",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WeChatSkillCore", targets: ["WeChatSkillCore"]),
        .executable(name: "wechat-draft-recovery-probe", targets: ["DraftRecoveryProbe"]),
        .executable(name: "wechat-reference-ui-probe", targets: ["ReferenceUIProbe"])
    ],
    targets: [
        .target(name: "WeChatSkillCore"),
        .executableTarget(name: "DraftRecoveryProbe", dependencies: ["WeChatSkillCore"]),
        .executableTarget(name: "ReferenceUIProbe", dependencies: ["WeChatSkillCore"]),
        .testTarget(name: "WeChatSkillCoreTests", dependencies: ["WeChatSkillCore"])
    ]
)
