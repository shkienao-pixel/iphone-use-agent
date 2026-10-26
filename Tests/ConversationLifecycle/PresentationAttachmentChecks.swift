import Foundation

@main struct PresentationAttachmentChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); checks += 1
        }
        func settle(_ predicate: () -> Bool) async throws {
            for _ in 0..<2000 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw NSError(domain: "PresentationAttachmentFixture", code: 1)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-attachments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("conversations.json")
        let conversation = AssistantConversation(store: AssistantConversationStore(url: path))
        let model = PresentationModel(conversation), owner = UUID(), transient = UUID()
        let view = PresentationAttachmentHarness(model, owner: owner)
        let a = conversation.currentConversationID
        // JPEG sentinel for identity/byte preservation; ImportChecks separately
        // validates actual encoded image decoding and normalization.
        let aImage = ComposerAttachment(name: "只属于A.jpg", kind: .image, byteCount: 4, text: "", imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let bText = ComposerAttachment(name: "只属于B.txt", kind: .text, byteCount: 9, text: "B独立正文", imageJPEG: nil)
        conversation.draft = "A尚未发送的正文"
        conversation.retainDraftAttachments([aImage], conversationID: a)
        conversation.claimPresentation(owner)
        view.synchronizeOnAppearance()
        expect(view.attachmentConversationID == a && view.attachmentDraft.items == [aImage], "Appearance restores A's exact durable image selection")
        let aSaved = conversation.conversations.first { $0.id == a }

        conversation.claimPresentation(transient)
        conversation.newConversation()
        let b = conversation.currentConversationID
        conversation.draft = "B本轮要求"
        conversation.retainDraftAttachments([bText], conversationID: b)
        view.showAttachmentPhotos = true; view.showAttachmentFiles = true; view.followingConversation = false
        view.conversationDidChange()
        expect(!conversation.ownsPresentation(owner) && view.attachmentConversationID == b && view.attachmentDraft.items == [bText], "An inactive mounted composer follows B before the owner-only media guard")
        expect(!view.showAttachmentPhotos && !view.showAttachmentFiles && view.followingConversation && view.lastSpokenMessage == nil, "Cross-chat local synchronization closes old pickers and resets following state")
        expect(view.sharedMediaCleanupCalls == 0, "An inactive mounted composer cannot clean up the current owner's shared media")
        expect(conversation.conversations.first { $0.id == a } == aSaved, "Synchronizing a hidden view does not rewrite A's archived draft or image bytes")
        expect(!conversation.releasePresentation(transient) && conversation.ownsPresentation(owner), "The surviving composer regains ownership after the transient view exits")
        let firstRequest = OfflineModel.shared.requests.count
        view.pressSend()
        try await settle { OfflineModel.shared.requests.count == firstRequest + 1 }
        expect(OfflineModel.shared.requests[firstRequest].attachments == [bText], "The complete production send method dispatches only B's selected text and never A's image")
        expect(conversation.messages.last?.attachments == [bText], "B's submitted message persists only B's explicit attachment")
        OfflineModel.shared.complete(firstRequest, answer: "B回答")
        try await settle { !conversation.loading }

        // Simulate event delivery being missed while the local view lost ownership.
        // The real send entry must repair its own stale local context before capture.
        conversation.claimPresentation(transient)
        conversation.newConversation()
        let c = conversation.currentConversationID
        conversation.draft = "C明确不附文件"
        view.showAttachmentFiles = true
        expect(view.attachmentConversationID == b && view.attachmentDraft.items == [bText], "Missed-event fixture genuinely retains the old view's B attachment")
        expect(!conversation.releasePresentation(transient) && conversation.ownsPresentation(owner), "The missed-event fixture restores the surviving presenter")
        let secondRequest = OfflineModel.shared.requests.count
        view.pressSend()
        try await settle { OfflineModel.shared.requests.count == secondRequest + 1 }
        expect(view.attachmentConversationID == c && view.attachmentDraft.items.isEmpty && !view.showAttachmentFiles, "Send preflight clears an old chat's tray and picker before reading attachment items")
        expect(OfflineModel.shared.requests[secondRequest].attachments.isEmpty && conversation.messages.last?.attachments == nil, "A fresh C request cannot forward B's text or A's image even without a change callback")
        OfflineModel.shared.complete(secondRequest, answer: "C回答")
        try await settle { !conversation.loading }

        // An old import belongs to the old local tray generation, not the newly
        // selected archive. Exercise the actual importer/store cancellation path.
        let oldFile = folder.appendingPathComponent("迟到的C文件.txt")
        try Data("只属于旧托盘的正文".utf8).write(to: oldFile)
        view.attachmentDraft.importFiles([oldFile])
        expect(view.attachmentDraft.importing, "A real local file import is in progress before switching to A")
        expect(conversation.openConversation(a), "The original A archive remains accessible")
        view.synchronizeOnAppearance()
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(view.attachmentConversationID == a && view.attachmentDraft.items == [aImage] && !view.attachmentDraft.importing, "Reappearing A restores its exact image and invalidates the late C import")
        expect(conversation.conversations.first { $0.id == a } == aSaved, "Opening and synchronizing A preserves its original archive contents and recency")
        let disk = AssistantConversationStore(url: path)
        expect(disk.records.first { $0.id == a }?.draftAttachments == [aImage], "A's durable image remains intact after hidden-view synchronization and two other sends")
        expect(disk.records.first { $0.id == b }?.messages.first?.attachments == [bText], "B's durable submitted attachment remains intact after C and A are selected")
        expect(disk.records.first { $0.id == c }?.messages.first?.attachments == nil, "C's durable message records no inherited attachments")
        print("\(checks) real presentation attachment synchronization/store/send checks passed; UI events explicit, platform/model boundaries offline")
    }
}
