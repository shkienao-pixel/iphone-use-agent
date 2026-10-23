import Foundation

let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let app = Bundle(url: appURL) else { fatalError("Cannot open built app bundle") }
let output = try AppleSupportSkill.instructions(in: app)
let resources = appURL.appendingPathComponent("Skills/apple-support-guide")
for name in ["official-sources", "iphone-operation", "troubleshooting"] {
    let expected = try String(contentsOf: resources.appendingPathComponent("references/\(name).md"), encoding: .utf8)
    precondition(output.contains(expected), "Built reference omitted from prompt: \(name)")
}
precondition(!output.contains("name: apple-support-guide"), "Frontmatter entered model instructions")
let ordinaryPhoneTask = try AppleSupportSkill.instructions(for: "打开微信朋友圈", in: app)
precondition(ordinaryPhoneTask.contains("手机操作索引"), "Phone operations were omitted for a normal task")
precondition(!ordinaryPhoneTask.contains("开发者帮助总入口"), "Unrelated developer directory bloated a normal task")
precondition(!ordinaryPhoneTask.contains("账户恢复等待"), "Unrelated troubleshooting advice bloated a normal task")
let appleRecoveryTask = try AppleSupportSkill.instructions(for: "iCloud 备份失败，如何恢复", in: app)
precondition(appleRecoveryTask.contains("官方文档来源索引"), "Apple source index omitted for an Apple support task")
precondition(appleRecoveryTask.contains("账户恢复等待"), "Troubleshooting guidance omitted for a recovery task")
precondition(ordinaryPhoneTask.utf8.count < output.utf8.count, "Irrelevant references were not reduced")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AppleSkill-" + UUID().uuidString + ".bundle")
try FileManager.default.createDirectory(at: temporary.appendingPathComponent("Skills"), withIntermediateDirectories: true)
try FileManager.default.copyItem(at: resources, to: temporary.appendingPathComponent("Skills/apple-support-guide"))
defer { try? FileManager.default.removeItem(at: temporary) }
let info: [String: Any] = ["CFBundleIdentifier": "dev.agentmouse.skill-check", "CFBundlePackageType": "BNDL"]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: temporary.appendingPathComponent("Info.plist"))
guard let fixture = Bundle(url: temporary) else { fatalError("Cannot open test bundle") }
let missing = temporary.appendingPathComponent("Skills/apple-support-guide/references/iphone-operation.md")
try FileManager.default.removeItem(at: missing)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Missing resource accepted") }
catch is AgentError { }
try "  \n".write(to: missing, atomically: true, encoding: .utf8)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Empty resource accepted") }
catch is AgentError { }
try "Restored reference".write(to: missing, atomically: true, encoding: .utf8)
let entry = temporary.appendingPathComponent("Skills/apple-support-guide/SKILL.md")
try "Broken frontmatter".write(to: entry, atomically: true, encoding: .utf8)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Malformed skill accepted") }
catch is AgentError { }
try "---\nname: apple-support-guide\n---\n".write(to: entry, atomically: true, encoding: .utf8)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Empty skill body accepted") }
catch is AgentError { }
print("14 bundled-skill checks passed. Full references: \(output.utf8.count) bytes; ordinary iPhone task: \(ordinaryPhoneTask.utf8.count) bytes. No network or device actions.")
