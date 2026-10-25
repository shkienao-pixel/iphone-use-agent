from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
signature = '    func stopAlarmCardFixtureA09() throws -> String {'
assert source.count(signature) == 1
start = source.index(signature)
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
Path(sys.argv[2]).write_text('''import Foundation
enum AgentError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
struct FixtureReceipt: Equatable { var id: UUID; var state: String; var result: String? }
@MainActor final class FixtureSystemTools {
    var receipts: [String: FixtureReceipt] = [:]
    var readable = true
''' + method + '\n}\n')
