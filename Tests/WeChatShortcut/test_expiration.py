"""Execute the production manual-operation methods against isolated state fakes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
model = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()
view = (root / "PhoneAgent/Views/WeChatShortcutView.swift").read_text()

def member(signature):
    start = model.index(signature)
    opening = model.index("{", start)
    depth = 0
    for i in range(opening, len(model)):
        if model[i] == "{": depth += 1
        elif model[i] == "}":
            depth -= 1
            if depth == 0: return model[start:i + 1]
    raise AssertionError("unterminated production method")

assert 'self?.expireManualAction(id: operationID' in view
assert 'self?.stop(cancelConversation: false)' not in view
methods = member("    func manualAction(allowsBackgroundScreen:") + "\n" + member("    func expireManualAction(id:")
source = r'''
import Foundation
final class FakeEngine { var running = false; var releasing = false; var stopCount = 0 }
final class FakeExecutor { var calibrationInProgress = false }
final class FakeWorkflow { var blocksGUI = false }
final class FakeBLE { var pointerConnectionGeneration = UUID(); var releases = 0
    func release(expectedConnection: UUID) async { releases += 1 } }
@MainActor final class FakeHost {
    var preparingAutomatically = false, queueRunning = false, queueSwitching = false
    var recordingAudioOwner: UUID?; var engine = FakeEngine(); var manualBusy = false
    var voicePending = false, calibrating = false; var executor = FakeExecutor()
    var workflowServices = FakeWorkflow(); var notice = ""; var manualContinuationRequired = false
    var manualScreenWorkflow = false; var manualActionID: UUID?; var manual: Task<Void, Never>?
    var ble = FakeBLE(); var waitingQueue = ["existing-a", "existing-b"]
    var pausedTask = "paused-original"
__METHODS__
}
@main struct Check {
    @MainActor static func main() async throws {
        let host = FakeHost(), id = UUID()
        var cancelled = false
        host.manualAction(allowsBackgroundScreen: true, id: id) {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch is CancellationError { cancelled = true; throw CancellationError() }
        }
        await Task.yield()
        host.expireManualAction(id: UUID(), message: "wrong")
        precondition(host.manualBusy && host.notice.isEmpty && !cancelled)
        host.expireManualAction(id: id, message: "expired")
        for _ in 0..<100 where host.manualBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(cancelled && !host.manualBusy && host.notice == "expired")
        precondition(host.waitingQueue == ["existing-a", "existing-b"] && host.pausedTask == "paused-original")
        precondition(host.engine.stopCount == 0 && host.ble.releases == 1)
        host.expireManualAction(id: id, message: "late")
        precondition(host.notice == "expired")
        print("Expiration: current operation alone cancelled; queue and paused task preserved")
    }
}
'''.replace("__METHODS__", methods)
with tempfile.TemporaryDirectory(prefix="wechat-expiration-") as directory:
    script = Path(directory) / "main.swift"
    script.write_text(source)
    executable = Path(directory) / "test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(script), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
