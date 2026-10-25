import Foundation

/// Always-loaded entry guide, independent of keyword-selected execution skills.
enum ConversationIntentSkill {
    private static let bundled = try? instructions(in: .main)

    static func instructions() throws -> String {
        guard let bundled else { throw AgentError.message("记忆与意图 skill 未正确打包，请重新安装 App") }
        return bundled
    }

    static func instructions(in bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/sela-intent"),
              let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count <= 24_576 else {
            throw AgentError.message("记忆与意图 skill 缺少有效资源")
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
              lines[1..<end].contains("name: sela-intent") else {
            throw AgentError.message("记忆与意图 skill 格式无效")
        }
        let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw AgentError.message("记忆与意图 skill 内容为空") }
        return body
    }
}
