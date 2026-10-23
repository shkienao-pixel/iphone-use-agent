import Foundation

enum PhoneControlSkill {
    // This is the same maintained SKILL.md distributed with the source package.
    private static let body: String? = {
        guard let url = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/phone-control"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }()

    static func instructions() throws -> String {
        guard let body else { throw AgentError.message("手机操控 skill 未正确打包，请重新安装 App") }
        return body
    }
}

enum AppleSupportSkill {
    // All references are embedded because the action model cannot read local files.
    // Cache the immutable app resources; do not perform network requests here.
    private static let body = try? instructions(in: .main)

    static func instructions() throws -> String {
        guard let body else { throw AgentError.message("苹果官方帮助 skill 未正确打包，请重新安装 App") }
        return body
    }

    static func instructions(for task: String) throws -> String {
        try instructions(for: task, in: .main)
    }

    static func instructions(for task: String, in bundle: Bundle) throws -> String {
        let directory = "Skills/apple-support-guide"
        let normalized = task.lowercased()
        let appleTopics = [
            "apple", "苹果", "官网", "官方文档", "官方帮助", "支持文章", "用户手册", "开发者帮助",
            "iphone", "ipad", "macos", "macbook", "apple watch", "airpods", "icloud",
            "siri", "快捷指令", "辅助触控", "辅助功能", "画中画", "apple pay", "vision pro"
        ]
        let problemTopics = [
            "故障", "异常", "报错", "错误", "无法", "打不开", "不能", "失败", "不工作", "卡住",
            "恢复", "备份", "同步", "丢失", "被盗", "重置", "抹掉", "账户", "账号", "密码", "维修", "保修"
        ]
        var selected: [(String, String, String)] = [
            ("SKILL", directory, "苹果官方帮助规则"),
            ("iphone-operation", directory + "/references", "iPhone 与 iPad 操作索引")
        ]
        if appleTopics.contains(where: normalized.contains) {
            selected.append(("official-sources", directory + "/references", "官方文档来源索引"))
        }
        if problemTopics.contains(where: normalized.contains) {
            selected.append(("troubleshooting", directory + "/references", "诊断和数据操作"))
        }
        return try selected.map { name, subdirectory, title in
            guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: subdirectory),
                  var text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError.message("苹果官方帮助 skill 缺少有效资源：\(name).md")
            }
            if name == "SKILL" {
                let lines = text.components(separatedBy: .newlines)
                guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
                    throw AgentError.message("苹果官方帮助 skill 的格式无效")
                }
                text = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AgentError.message("苹果官方帮助 skill 内容为空") }
            }
            return "## \(title)\n\(text)"
        }.joined(separator: "\n\n")
    }

    static func instructions(in bundle: Bundle) throws -> String {
        let directory = "Skills/apple-support-guide"
        let documents = [
            ("SKILL", directory, "苹果官方帮助规则"),
            ("official-sources", directory + "/references", "官方文档来源索引"),
            ("iphone-operation", directory + "/references", "iPhone 与 iPad 操作索引"),
            ("troubleshooting", directory + "/references", "诊断和数据操作")
        ]
        return try documents.map { name, subdirectory, title in
            guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: subdirectory),
                  var text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError.message("苹果官方帮助 skill 缺少有效资源：\(name).md")
            }
            if name == "SKILL" {
                let lines = text.components(separatedBy: .newlines)
                guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
                    throw AgentError.message("苹果官方帮助 skill 的格式无效")
                }
                text = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AgentError.message("苹果官方帮助 skill 内容为空") }
            }
            return "## \(title)\n\(text)"
        }.joined(separator: "\n\n")
    }
}
