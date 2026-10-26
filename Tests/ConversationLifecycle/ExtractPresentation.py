from pathlib import Path
import hashlib
import json
import sys

root, output = [Path(value).resolve() for value in sys.argv[1:]]
source = (root / "PhoneAgent/Views/AssistantViews.swift").read_text()

def block(signature):
    assert source.count(signature) == 1, signature
    start = source.index(signature)
    opening = source.index("{", start)
    depth, cursor = 1, opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor], source[opening + 1:cursor - 1]

helper, _ = block("    private func synchronizeConversationDraft()")
send, _ = block("    private func send()")
handler, handler_body = block("        .onChange(of: model.conversation.currentConversationID) { _, _ in\n            synchronizeConversationDraft()")
assert handler_body.startswith(" _, _ in\n")
handler_body = handler_body[len(" _, _ in\n"):]

scaffold = '''import Foundation
import SwiftUI

// Only platform media/readiness and the model transport are doubles. The
// production local synchronization, complete send method, attachment store,
// conversation controller and archive are compiled without substitutions.
enum SettingsStore { static func apiKey(for endpoint: String) -> String { "" } }
enum CameraObservationWindow {
    static func content(question: String, frames: [CameraObservationFrame], now: TimeInterval) throws {
        preconditionFailure("Camera is outside this attachment presentation test")
    }
}
@MainActor final class PresentationSpeech { var listening = false }
@MainActor final class PresentationCamera {
    var running = false
    var frame: ScreenFrame?
    func stop() { preconditionFailure("Camera is outside this attachment presentation test") }
    func sequence() -> [CameraObservationFrame] { [] }
}
@MainActor final class PresentationLiveCamera {
    struct Result { var text: String }
    var results: [Result] = []
    func stop() { preconditionFailure("Camera is outside this attachment presentation test") }
    func suspendForQuestion() async { preconditionFailure("Camera is outside this attachment presentation test") }
}
@MainActor final class PresentationModel {
    let conversation: AssistantConversation
    let settings = AgentSettings(), memories = MemoryStore()
    let speech = PresentationSpeech(), camera = PresentationCamera(), liveCamera = PresentationLiveCamera()
    struct History { var records: [PhoneTaskRecord] = [] }
    var history = History(), notice = "", modelReady = true, consentReady = true
    var consentRequests = 0
    init(_ conversation: AssistantConversation) { self.conversation = conversation }
    func requestConsent() { consentRequests += 1 }
}
@MainActor final class PresentationAttachmentHarness {
    let model: PresentationModel
    let presentationID: UUID
    let attachmentDraft = ComposerAttachmentStore()
    var attachmentConversationID: UUID?
    var showAttachmentPhotos = false, showAttachmentFiles = false, followingConversation = true
    var lastSpokenMessage: UUID?, composing = false, useCamera = false, videoMode = false
    var phase = ScenePhase.active
    var videoQuestionTask: Task<Void, Never>?, videoQuestionID = UUID()
    var sharedMediaCleanupCalls = 0
    var onModelSetup: () -> Void = { preconditionFailure("Model setup is outside this attachment presentation test") }
    init(_ model: PresentationModel, owner: UUID) { self.model = model; presentationID = owner }
    func stopConversationMedia() { sharedMediaCleanupCalls += 1 }
    func stopVoice() { preconditionFailure("Voice is outside this attachment presentation test") }
    func stopVideo() { preconditionFailure("Video is outside this attachment presentation test") }
    func startVideo() { preconditionFailure("Video is outside this attachment presentation test") }
    func finishAndSend() { preconditionFailure("Voice is outside this attachment presentation test") }
    func synchronizeOnAppearance() { synchronizeConversationDraft() }
    func pressSend() { send() }
    // PRODUCTION_HELPER
    // PRODUCTION_SEND
    func conversationDidChange() {
        // PRODUCTION_HANDLER
    }
}
'''
output.mkdir(parents=True, exist_ok=True)
(output / "PresentationHarness.swift").write_text(scaffold.replace("    // PRODUCTION_HELPER", helper)
    .replace("    // PRODUCTION_SEND", send).replace("        // PRODUCTION_HANDLER", handler_body))
(output / "presentation-extraction.json").write_text(json.dumps({
    "source": "PhoneAgent/Views/AssistantViews.swift",
    "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
    "completeMethods": ["synchronizeConversationDraft", "send"],
    "completeCurrentConversationChangeHandler": True,
    "substitutions": [],
    "regionSHA256": {name: hashlib.sha256(value.encode()).hexdigest() for name, value in
                     [("helper", helper), ("send", send), ("handler", handler)]},
    "limits": "SwiftUI event delivery is explicit; platform media/readiness and model transport are offline boundaries. Attachment store, importer, conversation and archive are real."
}, indent=2))
