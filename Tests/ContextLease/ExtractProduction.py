"""Extract current production observation code; keep host boundaries explicit."""
from pathlib import Path
import hashlib
import json
import sys

INPUTS = [
    "PhoneAgent/Services/AgentEngine.swift", "PhoneAgent/Services/CaptureService.swift",
    "PhoneAgent/Services/PhoneHarnessRuntime.swift", "PhoneAgent/Services/WorkflowObservationLease.swift",
    "PhoneAgent/Services/PhoneRasterEvidence.swift", "PhoneAgent/Stores/TaskHistoryStore.swift",
    "Tests/ProductState/Environment.swift", "Shared/FrameReadiness.swift", "Shared/RunMetrics.swift",
    "Shared/PhonePageAdapters.swift", "Shared/XiaohongshuPageAdapter.swift", "Shared/SystemToolRequest.swift",
    "Shared/PhoneHarness.swift", "Shared/AgentModels.swift", "Shared/MouseProtocol.swift",
    "Shared/ComposerAttachment.swift",
    "Shared/PhoneVisualControls.swift", "Shared/PhoneOverlayClassifier.swift",
    "Tests/ContextLease/ExtractProduction.py", "Tests/ContextLease/main.swift", "Tests/ContextLease/run.sh",
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def member(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    cursor = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]


def main():
    mode, root, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    manifest_path = out / "source-inputs.json"
    actual = {path: sha((root / path).read_bytes()) for path in INPUTS}
    if mode == "verify":
        expected = json.loads(manifest_path.read_text())
        assert actual == expected, "ContextLease source inputs changed during compile/replay"
        print("ContextLease source identity verified: " + str(len(actual)) + " current inputs")
        return
    assert mode == "extract"
    assert not manifest_path.exists(), "Use a fresh results directory; preserve earlier replay evidence"
    out.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(actual, indent=2) + "\n")
    capture = (root / "PhoneAgent/Services/CaptureService.swift").read_text()
    engine = (root / "PhoneAgent/Services/AgentEngine.swift").read_text()
    env = (root / "Tests/ProductState/Environment.swift").read_text()
    frame = member(capture, "struct ScreenFrame {")
    env = env.replace(member(env, "struct ScreenFrame {"), frame)
    assert env.count("struct UIImage {") == 1
    env = env.replace("struct UIImage {", "final class UIImage {")
    assert env.count("let cgImage: CGImage?") == 1
    env = env.replace("let cgImage: CGImage?", "let cgImage: CGImage?\n    init(cgImage: CGImage) { self.cgImage = cgImage }")
    assert env.count("return frozenFrame ?? ScreenFrame()") == 1
    env = env.replace("return frozenFrame ?? ScreenFrame()", "return frozenFrame")
    selected = 'var selectedID: String? = "offline-device"'
    assert env.count(selected) == 1
    env = env.replace(selected, selected + "\n    var pointerConnectionGeneration = UUID()")
    (out / "Environment.swift").write_text(env)

    interface = engine[engine.index("/// Host-generated evidence"):engine.index("\n@MainActor\nfinal class AgentEngine:")]
    outcome = member((root / "PhoneAgent/Stores/TaskHistoryStore.swift").read_text(), "enum TaskOutcome:")
    (out / "HarnessInterface.swift").write_text("import Foundation\n" + outcome + "\n" + interface)
    start = capture.index("            let frame = ScreenFrame(image: previous.image, jpeg: previous.jpeg, capturedAt: previous.capturedAt,")
    end = capture.index("\n            lastFrame = frame;", start)
    idle = capture[start:end]
    (out / "IdleConstructor.swift").write_text("import Foundation\n// Explicit synthetic delivery; never called by the frame getter.\nfunc contextAuditIdle(previous: ScreenFrame, now: Date, captureID: UUID, isFullDisplay: Bool) -> ScreenFrame {\n" + idle + "\n return frame\n}\n")
    method = member(engine, "    private func observeAction(goal: String, settings: AgentSettings, client: VisionClient, token: UUID,")
    scaffold = '''import Foundation
// Only observeAction below is production Engine code. Acquisition, logging,
// model and Mouse boundaries are explicit synthetic offline fixtures.
@MainActor final class ActualObserveActionProbe {
 let capture: CaptureService, executor: MouseExecutor
 var phoneHarness: PhoneHarnessDriving?
 var runMetrics: RunMetricsRecorder?
 var memoryContext: ((String) async -> String)?
 var logs: [AgentLogEntry] = []
 var taskContext = ""
 // This observation-only fixture has no submitted attachments; retain the
 // same optional checkpoint boundary as a full production task record.
 struct AttachmentCheckpoint { var attachments: [ComposerAttachment]? }
 var currentRecord: AttachmentCheckpoint?
 var taskAttachments: [ComposerAttachment] { currentRecord?.attachments ?? [] }
 let operation = UUID()
 var freshReads = 0
 var suppliedFrame: ScreenFrame?
 init(capture: CaptureService, executor: MouseExecutor, harness: PhoneHarnessRuntime) {
  self.capture = capture; self.executor = executor; phoneHarness = harness
 }
 private func stillCurrent(_ token: UUID) throws {
  try Task.checkCancellation(); guard token == operation else { throw CancellationError() }
 }
 private func freshFrame(after: Date, token: UUID, allowPointerWake: Bool) async throws -> ScreenFrame {
  try stillCurrent(token)
  guard let frame = capture.frame, frame.confirmedAt > after,
   (0..<1.5).contains(Date().timeIntervalSince(frame.confirmedAt)) else { throw AgentError.message("Synthetic producer did not supply a genuinely fresh initial frame") }
  freshReads += 1; suppliedFrame = frame; return frame
 }
 private func log(_ title: String, _ detail: String) {}
 private func transition(_ phase: AgentPhase, _ message: String) {}
 private func planningGoal(_ goal: String) -> String { goal }
 func run(settings: AgentSettings, after: Date) async throws -> (ScreenFrame, AgentAction) {
  var recoveries = 0, responseLimit = 256
  return try await observeAction(goal: "Synthetic readonly context test", settings: settings,
   client: VisionClient(settings: settings, apiKey: "offline-unused"), token: operation,
   step: 1, after: after, remainingRecoveries: &recoveries, responseLimit: &responseLimit)
 }
'''
    (out / "ObserveAction.swift").write_text(scaffold + method + "\n}\n")
    proof = {
        "productionObserveActionSHA256": sha(method.encode()),
        "productionScreenFrameSHA256": sha(frame.encode()),
        "nativeIdleConstructorSHA256": sha(idle.encode()),
        "hostBoundaries": ["reference UIImage around actual CGImage", "synthetic producer slot; getter never creates confirmations",
                           "synthetic BLE generation/Mouse/model", "complete production observeAction; synthetic acquisition and outer lifecycle"],
        "notClaimed": ["actual ScreenCaptureKit idle callback", "real Vision latency", "real model or input"],
    }
    proof["generatedSHA256"] = {name: sha((out / name).read_bytes()) for name in
                                ["Environment.swift", "HarnessInterface.swift", "IdleConstructor.swift", "ObserveAction.swift"]}
    (out / "extraction-proof.json").write_text(json.dumps(proof, indent=2) + "\n")


if __name__ == "__main__":
    main()
