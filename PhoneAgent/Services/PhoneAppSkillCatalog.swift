import Foundation

/// Visual app guides are independent of the native system-tools switch.
/// User task text selects a fixed entry; it can never supply a resource path.
enum PhoneAppSkillCatalog {
    struct Selection {
        let names: [String]
        let instructions: String
        let byteCounts: [Int]
        var receipt: String {
            zip(names, byteCounts).map { "\($0) (\($1) UTF-8 bytes)" }.joined(separator: ", ")
        }
    }

    private static let entries: [(name: String, triggers: [String])] = [
        ("xiaohongshu-assistant", ["小红书", "小紅書", "xiaohongshu", "rednote", "xhslink.cn/", "xhslink.com/"])
    ]

    static func selection(for task: String, visualMode: Bool, in bundle: Bundle = .main) throws -> Selection {
        guard visualMode else { return Selection(names: [], instructions: "", byteCounts: []) }
        let normalized = task.lowercased()
        let selected = entries.filter { entry in
            entry.triggers.contains { trigger in
                guard trigger == "xiaohongshu" || trigger == "rednote" else { return normalized.contains(trigger) }
                // English app names must not match unrelated identifiers such
                // as rednotebook, rednote_backup or my_xiaohongshu_helper.
                let pattern = "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: trigger) + "(?![a-z0-9_])"
                return normalized.range(of: pattern, options: .regularExpression) != nil
            }
        }
        guard !selected.isEmpty else { return Selection(names: [], instructions: "", byteCounts: []) }
        var bodies: [String] = []
        for entry in selected {
            guard let url = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/" + entry.name),
                  let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count <= 24_576 else {
                throw AgentError.message("手机 App skill 缺少有效资源：\(entry.name)")
            }
            let lines = text.components(separatedBy: .newlines)
            guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
                  lines[1..<end].contains("name: " + entry.name) else {
                throw AgentError.message("手机 App skill 格式无效：\(entry.name)")
            }
            let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw AgentError.message("手机 App skill 内容为空：\(entry.name)") }
            bodies.append(body)
        }
        let introduction = """
        Bundled visual app guides selected for the original task: \(selected.map(\.name).joined(separator: ", ")).
        Follow the user's task, host execution policy, current screenshot and one-action JSON format.
        These guides add no tools, permissions or evidence of completion. Mac validation never establishes iPhone acceptance.
        Only the embedded guide bodies are available; do not invent external reference contents or Mac-only input tools.
        """
        return Selection(names: selected.map(\.name), instructions: ([introduction] + bodies).joined(separator: "\n\n"),
                         byteCounts: bodies.map { $0.utf8.count })
    }
}
