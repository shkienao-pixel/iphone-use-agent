import Foundation

@MainActor private final class Vault {
    var value = "offline-recovery-credential"
    func connection() -> PaotuiConnection {
        PaotuiConnection(vault: .init(read: { self.value }, save: { self.value = $0 }),
            authorization: .init(start: { fatalError("offline") }, finish: { _ in fatalError("offline") }))
    }
}
@MainActor private final class Gate {
    var entered = false
    var blocked: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { blocked = $0 } }
    func release() { blocked?.resume(); blocked = nil }
    func wait() async { while !entered { await Task.yield() } }
}

@main struct RecoveryChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    @MainActor static func reject(_ operation: () throws -> Void, _ label: String) {
        do { try operation(); preconditionFailure(label) } catch { checks += 1 }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preparations.json"), receipt = root.appendingPathComponent("orders.json")
        let vault = Vault(), backend = Backend(), conversationID = UUID()
        func store(_ repository: PaotuiPreparationRepository, capacity: Int = 64,
                   factory: ((String) -> MeituanPaotuiClient)? = nil) -> MeituanPaotuiStore {
            MeituanPaotuiStore(connection: vault.connection(), receiptURL: receipt, clientFactory: factory ?? backend.client,
                preparationRepository: repository, sessionCapacity: capacity)
        }
        let repository = PaotuiPreparationRepository(url: url), first = store(repository)
        let session = first.session(for: conversationID)
        try await first.loadAddresses(for: session.ticket)
        var prep = session.preparation
        prep.draft = PaotuiDraft(service: .buy, recipientID: "address:1", senderID: "address:2", goods: "水一瓶 13800000000 " + vault.value,
            remark: "token=fixture-secret https://example.invalid/private?token=payment")
        prep.keyword = "Fixture Kitchen"; prep.city = "深圳"; prep.inquiryOnly = true
        try session.replacePreparation(prep)
        let snapshot = repository.snapshot(for: conversationID)!
        expect(snapshot.savedRecipientReference == "address:1" && snapshot.savedSenderReference == "address:2", "Only verified saved-address references persist")
        expect(snapshot.weight == nil && snapshot.category == nil, "Missing unused weight and category remain missing")
        let bytes = try Data(contentsOf: url), text = String(decoding: bytes, as: UTF8.self)
        expect(!text.contains(vault.value) && !text.contains("13800000000") && !text.contains("fixture-secret") && !text.contains("example.invalid"), "Snapshot excludes credentials, full phones, token assignments and private links")
        expect(!text.contains("Fixture address") && !text.contains("latitude") && !text.contains("contact"), "No address/contact body crosses the snapshot whitelist")
        expect(!text.contains("orderToken") && !text.contains("request") && !text.contains("quoteID") && !text.contains("grant"), "Snapshot cannot encode a quote, execution request or grant")
        for phone in ["138 0013 8000", "138-0013-8000", "+86 138 0013 8000", "0755-12345678", "+1 (202) 555-0100"] {
            expect(!PaotuiPreparationSnapshot.safeText("联系 " + phone, credential: "", limit: 500).contains(phone), "Persistence redacts formatted domestic and international phones")
        }
        for phone in ["13800138000", "138 0013 8000", "138-0013-8000", "+86 138 0013 8000", "8613800138000"] {
            expect(PaotuiAddress.redactingPhones("姓名 " + phone + " 地址") == "姓名 138****8000 地址", "Common display boundary normalizes only matched mainland mobile digits")
        }
        expect(PaotuiAddress.redactingPhones("2138001380009 address:1234567890123") == "2138001380009 address:1234567890123", "Common display helper does not redact longer adjacent numeric identifiers")
        expect(PaotuiAddress.redactingPhones("甲138 0013 8000 乙139-0013-8001") == "甲138****8000 乙139****8001", "Common display redacts multiple formatted phones without shifting ranges")
        for secret in [#"{"token":"shortvalue"}"#, #"{"orderToken":"shortvalue"}"#, "api_key='shortvalue'", "Bearer shortvalue"] {
            expect(!PaotuiPreparationSnapshot.safeText(secret, credential: "", limit: 500).contains("shortvalue"), "Persistence redacts quoted JSON and assigned short credentials")
        }
        expect(first.savedPreparations.count == 1 && first.savedPreparations[0].credentialMatches, "Recovery list is a safe current-credential projection")
        let restarted = store(PaotuiPreparationRepository(url: url)), controller = MeituanPaotuiConversation(store: restarted)
        let module = PaotuiModule(store: restarted, conversation: controller)
        expect(module.summary(for: conversationID) == nil && restarted.existingSession(for: conversationID) == nil, "Reading saved history never restores authority")
        var historyCard = PaotuiChatCard(conversationID: conversationID, kind: "confirm", title: "Historical confirmation")
        historyCard.quoteID = UUID(); historyCard.canCreateOrder = true
        expect(!module.presentation(for: historyCard, conversationID: conversationID).allows(.confirm), "Restarted historical confirmation is display-only")
        let restored = try restarted.restorePreparation(for: conversationID)
        expect(restored.sessionID != session.sessionID && restored.quotes.isEmpty && restored.currentCard == nil, "Explicit recovery creates a fresh Session without quote/card authority")
        expect(restored.draft.recipientID.isEmpty && restored.draft.senderID.isEmpty && restored.requiresAddressRefresh, "Saved references are inert until a fresh current book and explicit selection")
        expect(restored.restoredSavedAddressReferences == ["address:1", "address:2"] && restored.revalidatedSavedAddressReferences.isEmpty, "Saved address candidates have typed inert evidence")
        expect(restored.preparation.inquiryOnly && restored.draft.weight == nil && restored.draft.category == nil, "Inquiry restriction and unknown fields survive recovery")
        expect(restarted.addresses.isEmpty && restored.verifiedPlaces.isEmpty, "Recovery forces new address and merchant fetches")
        try await restarted.loadAddresses(for: restored.ticket)
        expect(!restored.requiresAddressRefresh && restored.revalidatedSavedAddressReferences == ["address:1", "address:2"], "Only current book references revalidate")
        expect(restored.draft.recipientID.isEmpty && restored.draft.senderID.isEmpty, "Revalidation does not automatically select an address")
        expect(!module.presentation(for: historyCard, conversationID: conversationID).isCurrent, "Recovery cannot activate an old history card")
        var current = restored.preparation
        current.draft.recipientID = "address:1"; current.draft.nearby = true
        try restored.replacePreparation(current)
        let quotes = try await restarted.preview(for: restored.ticket)
        expect(quotes.count == 1 && !restarted.canSubmit(quotes[0], for: restored.ticket), "A newly fetched quote retains inquiry-only limitation")
        expect(backend.submissions.isEmpty, "Recovery and fresh reads never replay an order")

        let fullID = UUID(), full = restarted.session(for: fullID)
        try full.replaceDraft(PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "Fresh water"))
        let actualHistoricalQuote = try await restarted.preview(for: full.ticket)[0]
        _ = try full.chooseQuote(actualHistoricalQuote.id, at: restarted.currentTime)
        var actualHistoricalCard = PaotuiChatCard(conversationID: fullID, kind: "confirm", title: "Old native confirmation")
        actualHistoricalCard.quoteID = actualHistoricalQuote.id; actualHistoricalCard.canCreateOrder = true
        _ = try full.offer(actualHistoricalCard)
        let oldTicket = full.ticket
        let historyRestart = store(PaotuiPreparationRepository(url: url))
        _ = try historyRestart.restorePreparation(for: fullID)
        let refused = await historyRestart.submitConfirmed(actualHistoricalQuote, for: oldTicket)
        if case .notDispatched = refused { checks += 1 } else { preconditionFailure("An old request regained submission authority") }
        expect(backend.submissions.isEmpty, "Even an actual prior quote/ticket cannot submit after explicit restart recovery")
        let historyConversation = MeituanPaotuiConversation(store: historyRestart)
        expect(!historyConversation.presentation(for: actualHistoricalCard, conversationID: fullID).isCurrent, "Actual prior confirmation never regains authority")
        try restarted.discardSavedPreparation(for: fullID)

        try restarted.installCredential("offline-another-credential")
        reject({ _ = try restarted.restorePreparation(for: conversationID) }, "Another credential restored an old scope")
        expect(!restarted.savedPreparations[0].credentialMatches && restarted.existingSession(for: conversationID) == nil, "Different credential changes scope without claiming a stable provider identity")
        try restarted.installCredential("offline-recovery-credential")
        let sameCredential = try restarted.restorePreparation(for: conversationID)
        expect(sameCredential.authorizationEpoch != restored.authorizationEpoch && sameCredential.quotes.isEmpty, "Same credential reinstall still creates a fresh local epoch and no rights")
        try restarted.discardSavedPreparation(for: conversationID)
        expect(restarted.savedPreparations.isEmpty && restarted.existingSession(for: conversationID) == nil, "Explicit discard closes live preparation and saved copy")
        expect(store(PaotuiPreparationRepository(url: url)).savedPreparations.isEmpty, "Clear survives a process restart")

        // A primary archive write failure leaves a durable independent marker.
        let failingID = UUID(), failURL = root.appendingPathComponent("write-failure.json")
        let normal = store(PaotuiPreparationRepository(url: failURL)), pending = normal.session(for: failingID)
        try pending.replaceDraft(PaotuiDraft(service: .send, goods: "文件", category: .document))
        let original = try Data(contentsOf: failURL)
        let failRepository = PaotuiPreparationRepository(url: failURL, commit: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let failing = store(failRepository)
        reject({ try failing.discardSavedPreparation(for: failingID) }, "Failed cleanup did not report storage failure")
        expect(try Data(contentsOf: failURL) == original, "Failed manifest commit byte-preserves the old snapshot")
        expect(PaotuiPreparationRepository(url: failURL).snapshot(for: failingID) == nil, "Durable tombstone wins after failed cleanup and restart")
        let fallbackURL = root.appendingPathComponent("clear-marker-failure.json")
        try original.write(to: fallbackURL)
        let markerFailure = PaotuiPreparationRepository(url: fallbackURL, commitTombstone: { _, _ in throw CocoaError(.fileWriteUnknown) })
        reject({ try markerFailure.discard(for: failingID) }, "Failed marker commit was not reported")
        expect(PaotuiPreparationRepository(url: fallbackURL).snapshot(for: failingID) == nil, "Atomic quarantine prevents restart revival if tombstone commit fails")
        let quarantines = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("clear-marker-failure.json.quarantine-") }
        expect(quarantines.count == 1, "One snapshot quarantine remains available")
        expect(try Data(contentsOf: quarantines[0]) == original, "Quarantine preserves exact bytes when clear cannot write a marker")
        let crashURL = root.appendingPathComponent("crash.json")
        try original.write(to: crashURL)
        let beforeCommitFailure = PaotuiPreparationRepository(url: crashURL, commit: { _, _ in throw CocoaError(.fileWriteUnknown) })
        reject({ try beforeCommitFailure.save(snapshot) }, "Interrupted staged write was accepted")
        expect(try Data(contentsOf: crashURL) == original, "Crash before atomic commit leaves original bytes intact")
        expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".paotui-preparation-") }.isEmpty, "Failed staged commits clean temporary files")

        // Unsupported/corrupt formats remain exact, and never affect the journal.
        let unknownQuote = UUID()
        let unknownData = try JSONSerialization.data(withJSONObject: [["quoteID": unknownQuote.uuidString, "account": "old-scope", "state": "pending", "createdAt": 10.0]])
        try unknownData.write(to: receipt)
        for (name, invalid) in [("future", Data(#"{"schemaVersion":99,"preparations":[]}"#.utf8)), ("corrupt", Data("{broken".utf8))] {
            let badURL = root.appendingPathComponent(name + ".json"); try invalid.write(to: badURL)
            let bad = PaotuiPreparationRepository(url: badURL), independent = store(bad)
            expect(!bad.isReadable && independent.preparationRecoveryIssue != nil && independent.savedPreparations.isEmpty, "Unreadable preparation fails closed with visible recovery issue")
            expect(independent.hasUnresolvedSubmission && independent.pendingReviews.count == 1, "Preparation recovery failure cannot erase or bypass independent unknown order facts")
            let fresh = independent.session(for: UUID()); try fresh.replaceDraft(PaotuiDraft(service: .buy, goods: "水"))
            expect(try Data(contentsOf: badURL) == invalid, "Future/corrupt bytes survive attempted preparation save")
            try? independent.discardSavedPreparation(for: failingID)
            expect(try Data(contentsOf: badURL) == invalid, "Discard can tombstone without overwriting unsupported bytes")
        }

        // The registry is bounded and does not evict active reads to make room.
        let capped = store(PaotuiPreparationRepository(url: root.appendingPathComponent("capacity.json")), capacity: 2)
        let a = capped.session(for: UUID()), b = capped.session(for: UUID())
        _ = try a.beginRead(.addresses, expected: a.ticket); _ = try b.beginRead(.places, expected: b.ticket)
        let rejectedSession = capped.session(for: UUID())
        expect(capped.activeSessionCount == 2 && !rejectedSession.isActive, "Capacity exhaustion returns no live authority and keeps bounded memory")
        expect(a.isActive && b.isActive && a.hasInFlightOperation && b.hasInFlightOperation, "Capacity does not evict in-flight preparation")
        a.close()
        let replacement = capped.session(for: UUID())
        expect(capped.activeSessionCount == 2 && replacement.isActive && b.isActive, "Closed/idle entries can be reclaimed without touching in-flight work")
        let resetID = UUID(), resetURL = root.appendingPathComponent("reset-empty.json"), resetting = store(PaotuiPreparationRepository(url: resetURL))
        let resettingSession = resetting.session(for: resetID)
        try resettingSession.replaceDraft(PaotuiDraft(service: .send, goods: "File"))
        try resettingSession.replacePreparation(.init())
        expect(PaotuiPreparationRepository(url: resetURL).snapshot(for: resetID) == nil, "Replacing preparation with empty requirements cannot resurrect the older draft")

        // Host pins cover model interpretation, before a network read exists.
        let pinURL = root.appendingPathComponent("host-pins.json"), pinStore = store(PaotuiPreparationRepository(url: pinURL), capacity: 1)
        let pinnedID = UUID(), pinned = pinStore.session(for: pinnedID)
        try pinned.replaceDraft(PaotuiDraft(service: .buy, goods: "Water"))
        let firstPin = UUID(), secondPin = UUID()
        try pinStore.retainHostRequest(for: pinnedID, requestID: firstPin)
        try pinStore.retainHostRequest(for: pinnedID, requestID: secondPin)
        pinStore.releaseHostRequest(for: pinnedID, requestID: firstPin)
        expect(!pinStore.session(for: UUID()).isActive && pinned.isActive, "An older host defer cannot unpin a newer model request")
        reject({ _ = try pinStore.restorePreparation(for: pinnedID) }, "Recovery replaced an active model interpretation")
        pinStore.releaseHostRequest(for: pinnedID, requestID: secondPin)
        expect(pinStore.session(for: UUID()).isActive, "The final host request release permits safe durable eviction")
        let samePinID = UUID(), samePin = UUID()
        try pinStore.retainHostRequest(for: samePinID, requestID: samePin)
        try pinStore.retainHostRequest(for: samePinID, requestID: samePin)
        pinStore.releaseHostRequest(for: samePinID, requestID: samePin)
        let sameSession = pinStore.session(for: samePinID)
        expect(sameSession.isActive && !pinStore.session(for: UUID()).isActive, "Repeated same-token callers use a refcount until both release")
        pinStore.releaseHostRequest(for: samePinID, requestID: samePin)
        expect(pinStore.session(for: UUID()).isActive, "Final same-token release frees the remaining pin")

        let hostStore = store(PaotuiPreparationRepository(url: root.appendingPathComponent("actual-host-pin.json")), capacity: 1)
        let hostID = UUID(), modelGate = Gate()
        let hostController = MeituanPaotuiConversation(store: hostStore, planner: { _, _, _ in await modelGate.hold(); return "{}" })
        let hostModule = PaotuiModule(store: hostStore, conversation: hostController)
        let hostTask = Task { try await hostModule.handle(.text(question: "买水", history: []), context: .init(conversationID: hostID, requestID: UUID())) }
        await modelGate.wait()
        expect(!hostStore.session(for: UUID()).isActive && hostStore.existingSession(for: hostID)?.isActive == true, "Actual Module pins before model interpretation and rejects capacity eviction")
        modelGate.release(); _ = try await hostTask.value
        expect(hostStore.session(for: UUID()).isActive, "Actual Module completion releases its own host pin")

        // A late provider reply after clear cannot rewrite a preparation snapshot.
        let lateURL = root.appendingPathComponent("late.json"), gate = Gate(), lateBackend = Backend()
        let late = store(PaotuiPreparationRepository(url: lateURL), factory: { key in
            MeituanPaotuiClient(credential: key, transport: { request in
                if request.url!.lastPathComponent == "delivery_preview" { await gate.hold() }
                return try lateBackend.respond(request)
            })
        })
        let lateID = UUID(), lateSession = late.session(for: lateID)
        try await late.loadAddresses(for: lateSession.ticket)
        try lateSession.replaceDraft(PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "水"))
        let ticket = lateSession.ticket
        let reading = Task { try await late.preview(for: ticket) }
        await gate.wait(); late.clearPreparation(for: lateID); gate.release()
        do { _ = try await reading.value; preconditionFailure("late reply published") } catch { checks += 1 }
        expect(late.existingSession(for: lateID) == nil && PaotuiPreparationRepository(url: lateURL).snapshot(for: lateID) == nil, "Late read cannot revive forgotten preparation in memory or after restart")
        expect(late.hasUnresolvedSubmission, "Clearing preparation retains unknown facts loaded independently")
        let diagnostics = late.diagnosticsSnapshot.jsonString
        expect(!diagnostics.contains(vault.value) && !diagnostics.contains("13800000000") && !diagnostics.contains("Fixture"), "Actual source recovery/read diagnostics contain typed correlation only")
        print("PASS: \(checks) preparation recovery checks against actual production sources")
    }
}
