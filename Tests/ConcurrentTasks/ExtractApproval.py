from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
def member(signature):
    start = source.index(signature); cursor = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}'); cursor += 1
    return source[start:cursor]
structure = member('struct ToolApproval:')
decide = member('    func decide(_ accepted: Bool, expectedID: UUID? = nil)')
a = source.index('        if requiresConfirmation || localOnly {', source.index('    func execute('))
b = source.index('        if request.operation.writes {', a)
approval = source[a:b]
Path(sys.argv[2]).write_text('import Foundation\n' + structure + '''
@MainActor final class ApprovalStateProbe {
    var pending: ToolApproval?
    var approval: CheckedContinuation<Bool, Never>?
''' + decide + '''
    func executeApproval(_ request: SystemToolRequest, taskID: UUID, requiresConfirmation: Bool = true, localOnly: Bool = false) async throws -> String {
''' + approval + '''
        return "synthetic approved tool receipt for " + taskID.uuidString
    }
}
''')
print('ConcurrentTasks: exact production ToolApproval, decide method and approval/cancellation block extracted without substitutions')
