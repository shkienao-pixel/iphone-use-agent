import Foundation
import Combine
import JavaScriptCore

struct SelaTaskSuggestion: Codable, Identifiable, Equatable {
    let id: String
    let appId: String
    let title: String
    var prompt: String
    var score: Int?
    var memoryDetail: String?
}

/// Runs the approved preview's local preference and date rules unchanged.
/// No browser, network, calendar read or task execution is involved.
@MainActor
final class SelaHomeContext: ObservableObject {
    @Published private(set) var suggestions: [SelaTaskSuggestion] = []
    private let context: JSContext?
    private let catalog: [SelaTaskSuggestion]
    init(bundle: Bundle = .main) {
        context = JSContext()
        struct Catalog: Decodable { let hooks: [SelaTaskSuggestion] }
        catalog = bundle.url(forResource: "SelaTaskCatalog", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Catalog.self, from: $0).hooks } ?? []
        if let url = bundle.url(forResource: "SelaHomeRules", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) { context?.evaluateScript(script) }
    }
    func update(records: [AssistantMemory], enabled: Bool) {
        let iso = ISO8601DateFormatter()
        let memories: [[String: Any]] = records.map {
            ["id": $0.id.uuidString, "title": $0.title, "text": $0.text,
             "kind": $0.kind.rawValue, "source": $0.source, "enabled": $0.enabled,
             "createdAt": iso.string(from: $0.createdAt), "updatedAt": iso.string(from: $0.updatedAt)]
        }
        context?.objectForKeyedSubscript("state")?.setObject(["useMemories": enabled, "memories": memories], forKeyedSubscript: "toolDetail" as NSString)
        refresh()
    }
    func greeting(at date: Date) -> String {
        context?.setObject(date.timeIntervalSince1970 * 1000, forKeyedSubscript: "nativeNow" as NSString)
        return context?.evaluateScript("homeGreetingForDate(new Date(nativeNow))")?.toString() ?? "今天过得怎么样？"
    }
    func refresh() {
        let previous = Set(suggestions.map(\.id))
        let memory = context?.objectForKeyedSubscript("homeHookMemoryContext")?.call(withArguments: [])
        let personalized = catalog.map { item -> SelaTaskSuggestion in
            guard let data = try? JSONEncoder().encode(item),
                  let dict = try? JSONSerialization.jsonObject(with: data),
                  let value = context?.objectForKeyedSubscript("personalizeHomeHook")?.call(withArguments: [dict, memory as Any]),
                  let json = value.toDictionary(), JSONSerialization.isValidJSONObject(json),
                  let result = try? JSONSerialization.data(withJSONObject: json),
                  let decoded = try? JSONDecoder().decode(SelaTaskSuggestion.self, from: result) else { return item }
            return decoded
        }
        let grouped = Dictionary(grouping: personalized, by: \.appId)
        let candidates = grouped.values.compactMap { all -> SelaTaskSuggestion? in
            let fresh = all.filter { !previous.contains($0.id) }
            return (fresh.isEmpty ? all : fresh).shuffled().sorted { ($0.score ?? 0) > ($1.score ?? 0) }.first
        }
        suggestions = Array(candidates.shuffled().sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(3))
    }
}
