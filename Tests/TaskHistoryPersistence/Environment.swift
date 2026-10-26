import Foundation

// Only the record's log/context value boundaries are supplied locally. The
// production repository, attachment validation and native-result models compile
// unchanged; these checks never construct a model, device or execution engine.
struct AgentLogEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var step: Int
    var title: String
    var detail: String
}
struct TaskContextMemory: Codable {
    var compactedEntryCount = 0
    var retainedEntryCount = 0
    var truncatedCharacterCount = 0
}
