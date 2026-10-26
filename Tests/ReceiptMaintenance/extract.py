from pathlib import Path
import sys

def member(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    position = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[position] == '{') - (text[position] == '}')
        position += 1
    return text[start:position]

root, output = map(Path, sys.argv[1:])
source = (root / 'PhoneAgent/Services/SystemTools.swift').read_text()
vm = (root / 'PhoneAgent/PhoneAgentViewModel.swift').read_text()
store = (root / 'PhoneAgent/Stores/TaskHistoryStore.swift').read_text()
methods = '\n'.join(member(source, signature) for signature in [
    '    func receiptMaintenanceBlockedReason(', '    func clearReceipts(context:',
    '    func completedTaskReceipts(', '    func hasUnresolvedWrite(', '    private func persistReceipts('
])
context = member(vm, '    var toolReceiptMaintenanceContext:')
outcome = member(store, 'enum TaskOutcome:')
production = '''import Foundation
enum AgentError: LocalizedError { case message(String); var errorDescription: String? { switch self { case .message(let text): return text } } }
@MainActor final class SystemTools {
    struct Receipt: Codable { var id: UUID; var state: String; var result: String? }
    var pending: Bool? = nil
    var receipts: [String: Receipt] = [:]
    var readable = true
    var error = ""
    var receiptURL: URL
    init(url: URL) { receiptURL = url }
    func seed(_ values: [String: Receipt]) throws { try persistReceipts(values) }
'''+methods+'''
}
'''+outcome+'''
struct Checkpoint { var id: UUID; var outcome: TaskOutcome }
struct QueuedCheckpoint { var id: UUID; var resumable: Bool }
@MainActor final class History { var records: [Checkpoint] = []; var error = "" }
@MainActor final class Queue { var items: [QueuedCheckpoint] = []; var error = "" }
@MainActor final class Engine { var currentRecord: Checkpoint?; var executionSettled = true }
@MainActor final class Background { var records: [Checkpoint] = []; var checkpointRecords: [Checkpoint] { records }; var hasUnsettledExecution = false }
@MainActor final class Host {
    let history = History(), taskQueue = Queue(), engine = Engine(), backgroundTasks = Background()
    var queueRunning = false, queueSwitching = false, preparingAutomatically = false
'''+context+'''
}
'''
output.write_text(production)
settings = (root / 'PhoneAgent/Views/SettingsView.swift').read_text()
assert 'model.cleanEndedTaskReceipts()' in settings
assert '.disabled(model.toolReceiptMaintenanceBlockedReason != nil)' in settings
assert 'tools.clearReceipts()' not in settings
background = (root / 'PhoneAgent/Services/BackgroundTaskCoordinator.swift').read_text()
assert 'var hasUnsettledExecution:' in background and '$0.engine?.executionSettled == false' in background
assert 'try tools.clearReceipts(context: toolReceiptMaintenanceContext)' in vm
