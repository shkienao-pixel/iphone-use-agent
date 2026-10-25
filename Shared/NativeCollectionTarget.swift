import Foundation

/// Select from the caller's authorized EventKit snapshot. Never guess a target.
enum NativeCollectionTarget {
    struct Descriptor: Equatable {
        let id: String
        let title: String
        let writable: Bool
    }
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    static func select(_ candidates: [Descriptor], named name: String?, defaultID: String?, label: String) throws -> Descriptor {
        let target: Descriptor
        if let name {
            let title = normalized(name)
            guard !title.isEmpty else { throw AgentError.message("请填写目标\(label)名称") }
            let matches = candidates.filter { normalized($0.title) == title }
            guard matches.count == 1 else {
                throw AgentError.message(matches.isEmpty ? "找不到指定\(label)：\(name)；没有改写到默认位置" : "存在多个同名\(label)：\(name)；请先区分名称，没有创建")
            }
            target = matches[0]
        } else {
            guard let defaultID, let value = candidates.first(where: { $0.id == defaultID }) else {
                throw AgentError.message("没有可写入的默认\(label)")
            }
            target = value
        }
        guard target.writable else { throw AgentError.message("目标\(label)不可写入：\(target.title)") }
        return target
    }
}
