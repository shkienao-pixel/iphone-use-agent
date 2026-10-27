import Foundation
import CryptoKit
import Darwin

@MainActor private final class Backend {
    var calls = 0
    var beforeReply: (() throws -> Void)?
    func client(_ credential: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: credential, transport: { request in
            self.calls += 1
            try self.beforeReply?()
            let data: [String: Any] = request.url!.lastPathComponent == "get_order_status" ?
                ["statusDesc": "归档订单的配送状态"] : ["orderId": "native-order-\(self.calls)"]
            let payload = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
            let bytes = try JSONSerialization.data(withJSONObject: ["code": 0, "result": "SUCCESS", "data": String(decoding: payload, as: UTF8.self)])
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }
}

@main struct ArchiveChecks {
    @MainActor private static var checks = 0
    private static let time = Date(timeIntervalSinceReferenceDate: 800_000_000)
    @MainActor private static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
        checks += 1; let result = try value(); precondition(result, label)
    }
    @MainActor private static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(label) } catch { checks += 1 }
    }
    private static func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private static func object(_ path: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any] }
    private static func rows(_ path: URL) throws -> [[String: Any]] { try object(path)["receipts"] as! [[String: Any]] }
    private static func pages(_ path: URL) throws -> [URL] {
        let directory = path.appendingPathExtension("archive")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func row(_ index: Int, state: String = "created", account: String = "legacy-scope") -> [String: Any] {
        var value: [String: Any] = ["attemptID": UUID().uuidString, "quoteID": UUID().uuidString, "account": account,
                                  "state": state, "createdAt": index, "reviews": [], "deliveryAmount": ["currency": "CNY", "minorUnits": 1800]]
        if state == "created" { value["orderID"] = "legacy-order-\(index)" }
        if state == "reviewed" { value["reviews"] = [["conclusion": "believesCreated", "reviewedAt": 0, "source": "user_report_in_sela"]] }
        return value
    }
    private static func seed(_ path: URL, _ rows: [[String: Any]], version: Int = 2) throws {
        try bytes(["schemaVersion": version, "receipts": rows]).write(to: path)
    }
    @MainActor private static func quote(_ account: String) -> PaotuiQuote {
        PaotuiQuote(id: UUID(), draft: PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "水"),
                    senderTitle: "", recipientTitle: "Fixture", serviceTitle: "帮买", distance: "1公里", estimate: "",
                    fee: 18, originalFee: 18, goodsPaymentNote: "", quotedAt: time, agreementURL: nil,
                    agreementTitle: "", account: account, request: [:], orderToken: "fixture", couponViewID: "")
    }
    private static func context(_ quote: PaotuiQuote, epoch: UUID = UUID()) -> PaotuiAttemptContext {
        PaotuiAttemptContext(sessionID: UUID(), conversationID: UUID(), taskOrigin: nil, revision: 8,
                             credentialEpoch: epoch, quoteID: quote.id,
                             credentialBinding: PaotuiCredentialBinding(credentialScope: quote.account))
    }
    private static func digest(_ value: Any) throws -> String {
        SHA256.hash(data: try bytes(value)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = PaotuiClock(now: { time })
        let path = directory.appendingPathComponent("capacity.json")
        var nearLimit = (0..<1997).map { row($0) }
        nearLimit += [row(1997, state: "reviewed"), row(1998, state: "unknown"), row(1999, state: "unknown", account: "foreign-credential-scope")]
        try seed(path, nearLimit)
        let journal = PaotuiOrderJournal(url: path, clock: clock)
        let initial = journal.maintenanceSnapshot
        expect(initial.isReadable && initial.activeReceiptCount == 2000 && initial.resolvedReceiptCount == 1998 &&
               initial.unresolvedReceiptCount == 2 && initial.activeCapacity == 2000 && initial.canArchive,
               "Near-limit migrated history exposes real active/resolved/unknown capacity counters")
        try expect(rows(path).allSatisfy { $0["context"] == nil && ($0["credentialBinding"] as? [String: Any])?["kind"] as? String == "credentialScope" },
                   "V2 credential hashes become explicit scopes; missing original epochs/sessions stay unknown")
        let unknownIDs = journal.pendingReviews(account: "legacy-scope").map(\.id)
        expect(journal.pendingReviews(account: "legacy-scope", credentialEpoch: UUID()).allSatisfy { !$0.isCurrentAuthorization },
               "Legacy records do not invent an authorization epoch even when the credential scope matches")
        try journal.recordReview(attemptID: unknownIDs[0], conclusion: .stillUnknown)
        let knownQuote = UUID(uuidString: nearLimit[1996]["quoteID"] as! String)!
        let service = PaotuiOrderService(journal: journal, clock: clock)
        try expect(service.archiveResolved() == 1998, "Explicit service maintenance moves all 1998 resolved rows")
        expect(journal.maintenanceSnapshot.activeReceiptCount == 2 && journal.maintenanceSnapshot.archivedReceiptCount == 1998 &&
               journal.maintenanceSnapshot.archivePageCount == 1 && !journal.maintenanceSnapshot.canArchive,
               "Resolved archive frees active capacity without dropping unknowns")
        expect(journal.pendingReviews(account: "legacy-scope").map(\.id) == unknownIDs && journal.hasUnresolvedSubmission,
               "Unknown and still-unknown review facts stay active with a global credential-independent barrier")
        rejects("Archiving does not authorize a new submission while another scope is unknown") {
            _ = try journal.beginAttempt(quote: quote("third-credential-scope"), account: "third-credential-scope")
        }
        expect(journal.lastOrderID(account: "legacy-scope") == "legacy-order-1996" && journal.lastOrderID(account: "foreign-credential-scope") == nil &&
               journal.knowsCreatedOrder(orderID: "legacy-order-1996", account: "legacy-scope") &&
               journal.orderURL(quoteID: knownQuote, account: "legacy-scope")?.lastPathComponent == "legacy-order-1996",
               "All created-order lookups preserve scope across archived pages")
        expect(!journal.knowsCreatedOrder(orderID: nearLimit[1997]["attemptID"] as! String, account: "legacy-scope"),
               "Archived human belief never becomes a provider-created order fact")
        let archivePage = try pages(path)[0]
        try expect(archivePage.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true &&
                   path.appendingPathExtension("archive").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                   "Archive page and directory inherit backup exclusion before commits")
        let restarted = PaotuiOrderJournal(url: path, clock: clock)
        expect(restarted.isReadable && restarted.maintenanceSnapshot.archivedReceiptCount == 1998 && restarted.pendingReviews(account: "legacy-scope").map(\.id) == unknownIDs,
               "Archived receipts and every unresolved fact survive restart")
        try restarted.recordReview(attemptID: unknownIDs[0], conclusion: .believesNotCreated)
        try expect(restarted.archiveResolved() == 1 && restarted.hasUnresolvedSubmission && restarted.maintenanceSnapshot.archivePageCount == 2,
                   "A resolved human judgment can archive while the remaining unknown still blocks all submissions")
        try restarted.recordReview(attemptID: unknownIDs[1], conclusion: .believesCreated)
        try expect(restarted.archiveResolved() == 1 && !restarted.hasUnresolvedSubmission && restarted.maintenanceSnapshot.activeReceiptCount == 0 &&
                   restarted.maintenanceSnapshot.archivedReceiptCount == 2000,
                   "Only explicit judgments resolve unknowns; all original review histories remain archived")
        expect(restarted.lastOrderID(account: "foreign-credential-scope") == nil && restarted.lastOrderID(account: "legacy-scope") == "legacy-order-1996",
               "Neither kind of human judgment fabricates a platform order ID")
        let backend = Backend()
        let statusService = PaotuiOrderService(journal: restarted, clientFactory: backend.client, clock: clock)
        let status = try await statusService.status(orderID: "legacy-order-1996", credential: "offline", account: "legacy-scope", validateAuthorization: {})
        expect(status == "归档订单的配送状态" && backend.calls == 1, "Known archived provider receipts retain native status-query authority")

        let fullPath = directory.appendingPathComponent("all-resolved.json")
        try seed(fullPath, (0..<2000).map { row($0) })
        let full = PaotuiOrderJournal(url: fullPath, clock: clock)
        rejects("2000 active resolved rows reach capacity before explicit maintenance") { _ = try full.beginAttempt(quote: quote("legacy-scope"), account: "legacy-scope") }
        try expect(full.archiveResolved() == 2000, "Exactly 2000 active rows can be archived in a durable bounded page")
        let resumed = try full.beginAttempt(quote: quote("legacy-scope"), account: "legacy-scope")
        expect(full.pendingReviews(account: "legacy-scope").map(\.id) == [resumed] && full.maintenanceSnapshot.archivedReceiptCount == 2000,
               "Archiving restores submission capacity without truncating history")

        let orderingPath = directory.appendingPathComponent("legacy-ordering.json")
        var oldest = row(0, state: "unknown")
        let newer = row(1)
        // Equal timestamps also preserve the actual legacy file ordering.
        oldest["createdAt"] = 1
        try seed(orderingPath, [oldest, newer])
        let ordered = PaotuiOrderJournal(url: orderingPath, clock: clock)
        try expect(ordered.archiveResolved() == 1 && ordered.lastOrderID(account: "legacy-scope") == "legacy-order-1",
                   "Archiving a newer receipt preserves original journal order")
        try ordered.markCreated(attemptID: UUID(uuidString: oldest["attemptID"] as! String)!, orderID: "older-attempt-resolved-late")
        expect(ordered.lastOrderID(account: "legacy-scope") == "legacy-order-1",
               "A legacy older unknown resolving after archive cannot replace the later last-order fact, even at equal times")
        try ordered.archiveResolved()
        expect(PaotuiOrderJournal(url: orderingPath, clock: clock).lastOrderID(account: "legacy-scope") == "legacy-order-1",
               "Persisted original-file sequence preserves last-order lookup across archive pages and restart")

        // Exercise the actual commit boundary, before archive durability and
        // after archive durability but before primary pruning, without HTTP.
        for failAfterArchive in [false, true] {
            let faultPath = directory.appendingPathComponent(failAfterArchive ? "after-archive.json" : "before-archive.json")
            try seed(faultPath, [row(1), row(2, state: "unknown")])
            _ = PaotuiOrderJournal(url: faultPath, clock: clock)
            let oldBytes = try Data(contentsOf: faultPath)
            var commits = 0, changes = 0
            let fault = PaotuiOrderJournal(url: faultPath, clock: clock, commit: { staged, destination in
                commits += 1
                try expect(staged.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                           "Protection/backup metadata is staged before every archive/prune commit")
                if !failAfterArchive || destination == faultPath { throw CocoaError(.fileWriteNoPermission) }
                try expect(Data(contentsOf: faultPath) == oldBytes, "Archive commits before any active-primary prune")
                guard rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            })
            let prior = fault.maintenanceSnapshot
            fault.onChange = { changes += 1 }
            rejects("Injected archive/prune failure must report failure") { _ = try fault.archiveResolved() }
            try expect(fault.maintenanceSnapshot == prior && Data(contentsOf: faultPath) == oldBytes && changes == 0,
                       "Both failure positions preserve old primary bytes, in-memory counters and notification state")
            try expect(pages(faultPath).count == (failAfterArchive ? 1 : 0) && commits == (failAfterArchive ? 2 : 1),
                       "A failed prune leaves one durable archive page; a failed archive leaves none")
            let recovered = PaotuiOrderJournal(url: faultPath, clock: clock)
            expect(recovered.isReadable && recovered.hasUnresolvedSubmission && recovered.pendingReviews(account: "legacy-scope").count == 1,
                   "Restart after either interruption preserves the unresolved global barrier")
            expect(recovered.maintenanceSnapshot.activeReceiptCount == (failAfterArchive ? 1 : 2) &&
                   recovered.maintenanceSnapshot.archivedReceiptCount == (failAfterArchive ? 1 : 0) &&
                   recovered.lastOrderID(account: "legacy-scope") == "legacy-order-1",
                   "Restart deduplicates only identical durable attempt facts without losing known-order lookups")
        }

        // Create real typed native correlation and verify different generations
        // and credentials retain their original immutable receipt facts.
        let nativePath = directory.appendingPathComponent("native.json")
        let native = PaotuiOrderJournal(url: nativePath, clock: clock)
        let recorder = PaotuiDiagnostics(clock: clock)
        let nativeBackend = Backend()
        let nativeService = PaotuiOrderService(journal: native, clientFactory: nativeBackend.client, clock: clock, diagnostics: recorder)
        let token = "offline-native-token"
        let scope = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let firstQuote = quote(scope), firstContext = context(quote(scope))
        // The mismatched quote must be rejected before an attempt or transport.
        if case .notDispatched = await nativeService.submit(quote: firstQuote, credential: token, account: scope, context: firstContext, validate: {}, invalidate: {}) {
            expect(nativeBackend.calls == 0 && native.maintenanceSnapshot.activeReceiptCount == 0, "Mismatched quote/context cannot dispatch or invent a receipt")
        } else { preconditionFailure("Mismatched quote context dispatched") }
        let originalContext = context(firstQuote)
        var inFlightID: UUID?
        nativeBackend.beforeReply = {
            inFlightID = native.pendingReviews(account: scope).first?.id
            expect(native.attemptContext(attemptID: inFlightID!) == originalContext, "Original native grant context is durable before HTTP result")
            expect(native.pendingReviews(account: scope, credentialEpoch: originalContext.credentialEpoch)[0].isCurrentAuthorization &&
                   !native.pendingReviews(account: scope, credentialEpoch: UUID())[0].isCurrentAuthorization &&
                   native.pendingReviews(account: scope, credentialEpoch: UUID())[0].isSameCredentialScope,
                   "Current authorization requires the original known epoch; same-token new generations remain distinguishable")
            rejects("Archive maintenance cannot race an in-flight submission") { _ = try nativeService.archiveResolved() }
        }
        if case .created = await nativeService.submit(quote: firstQuote, credential: token, account: scope, context: originalContext, validate: {}, invalidate: {}) {} else {
            preconditionFailure("Native context fixture failed")
        }
        let firstAttempt = inFlightID!
        let completedEvent = recorder.snapshot.events.last { $0.command == .submitOrder && $0.result == .created }!
        expect(completedEvent.context.attemptID == firstAttempt && completedEvent.context.quoteID == firstQuote.id &&
               completedEvent.context.sessionID == originalContext.sessionID && completedEvent.context.conversationID == originalContext.conversationID &&
               completedEvent.context.revision == originalContext.revision && completedEvent.context.credentialEpoch == originalContext.credentialEpoch,
               "Actual service-created diagnostics correlate native session, conversation, revision, epoch, quote and durable attempt")
        try expect(native.archiveResolved() == 1 && native.attemptContext(attemptID: firstAttempt) == originalContext,
                   "Archiving preserves original correlation and credential-generation facts")
        nativeBackend.beforeReply = nil
        let nextQuote = quote(scope)
        let actualNextContext = context(nextQuote)
        if case .created = await nativeService.submit(quote: nextQuote, credential: token, account: scope, context: actualNextContext, validate: {}, invalidate: {}) {} else {
            preconditionFailure("Same credential new epoch fixture failed")
        }
        try expect(rows(nativePath)[0]["context"] as? [String: Any] != nil && originalContext.credentialEpoch != actualNextContext.credentialEpoch &&
                   native.attemptContext(attemptID: firstAttempt) == originalContext,
                   "Same credential under a new epoch creates a new context and preserves original facts")
        let otherToken = "another-offline-native-token"
        let otherScope = SHA256.hash(data: Data(otherToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let otherQuote = quote(otherScope)
        let actualOtherContext = context(otherQuote)
        if case .created = await nativeService.submit(quote: otherQuote, credential: otherToken, account: otherScope, context: actualOtherContext, validate: {}, invalidate: {}) {} else {
            preconditionFailure("Distinct credential fixture failed")
        }
        expect(native.lastOrderID(account: scope) == "native-order-2" && native.lastOrderID(account: otherScope) == "native-order-3" &&
               !native.knowsCreatedOrder(orderID: "native-order-3", account: scope), "Distinct credentials never merge order lookup or provider facts")
        let forged = quote(scope), forgedContext = context(forged)
        if case .notDispatched = await nativeService.submit(quote: forged, credential: otherToken, account: scope, context: forgedContext, validate: {}, invalidate: {}) {
            expect(nativeBackend.calls == 3, "A forged scope cannot bind a new credential to another credential's receipt history")
        } else { preconditionFailure("Forged credential context dispatched") }
        let reloadedNative = PaotuiOrderJournal(url: nativePath, clock: clock)
        expect(reloadedNative.attemptContext(attemptID: firstAttempt) == originalContext &&
               reloadedNative.knowsCreatedOrder(orderID: "native-order-1", account: scope), "Correlated native and archived facts survive restart")
        let safeLog = recorder.snapshot.jsonString
        expect(!safeLog.contains(token) && !safeLog.contains(scope) && !safeLog.contains("credentialScope"),
               "Native diagnostics never export credential data or fingerprints")

        let referencePath = directory.appendingPathComponent("human-reference.json")
        var oldUnknown = row(0, state: "unknown")
        oldUnknown["reviews"] = [["conclusion": "stillUnknown", "reviewedAt": 0, "source": "user_report_in_sela"]]
        try seed(referencePath, [oldUnknown])
        let referenceJournal = PaotuiOrderJournal(url: referencePath, clock: clock)
        let referenceAttempt = referenceJournal.pendingReviews(account: "legacy-scope")[0].id
        let referenceQuoteID = UUID(uuidString: oldUnknown["quoteID"] as! String)!
        expect(referenceJournal.pendingReviews(account: "legacy-scope")[0].reportedOrderReference == nil &&
               referenceJournal.pendingReviews(account: "legacy-scope")[0].lastConclusion == .stillUnknown,
               "Old human reviews decode missing reference as unknown without inventing a provider order")
        let referenceBackend = Backend(), referenceDiagnostics = PaotuiDiagnostics(clock: clock)
        let referenceService = PaotuiOrderService(journal: referenceJournal, clientFactory: referenceBackend.client,
                                                 clock: clock, diagnostics: referenceDiagnostics)
        let beforeInvalidReferences = try Data(contentsOf: referencePath)
        let beforeInvalidSnapshot = referenceJournal.maintenanceSnapshot
        for invalid in ["https://npay.meituan.com/?pay_token=secret", "13800000000", "01012345678", "+8613800000000", "sk-proj-123456789", "pay_token_123456", "MT order 123", "MT/123456", "订单123456", "no-digits", String(repeating: "A", count: 65) + "1"] {
            rejects("Invalid human reference is rejected before any write") {
                try referenceService.recordReview(attemptID: referenceAttempt, conclusion: .believesCreated, reportedOrderReference: invalid)
            }
            try expect(Data(contentsOf: referencePath) == beforeInvalidReferences && referenceJournal.maintenanceSnapshot == beforeInvalidSnapshot &&
                       referenceJournal.pendingReviews(account: "legacy-scope")[0].reportedOrderReference == nil && referenceJournal.hasUnresolvedSubmission,
                       "Invalid reference leaves old bytes, unknown barrier, counter and review projection unchanged")
        }
        let foundReference = "MT-20261026-USER001"
        try referenceService.recordReview(attemptID: referenceAttempt, conclusion: .stillUnknown,
                                           reportedOrderReference: "  " + foundReference + "  ")
        let withReference = referenceJournal.pendingReviews(account: "legacy-scope")[0]
        expect(withReference.reportedOrderReference == foundReference && withReference.reviewedAt == time &&
               withReference.reviewSource == "user_report_in_sela" && withReference.lastConclusion == .stillUnknown && referenceJournal.hasUnresolvedSubmission,
               "A user-found reference retains explicit human source/time while still-unknown remains globally blocked")
        try expect(rows(referencePath)[0]["orderID"] == nil && referenceJournal.lastOrderID(account: "legacy-scope") == nil &&
                   !referenceJournal.knowsCreatedOrder(orderID: foundReference, account: "legacy-scope") &&
                   referenceJournal.orderURL(quoteID: referenceQuoteID, account: "legacy-scope")?.absoluteString == "https://i.meituan.com/",
                   "A reported reference never becomes provider order ID, last order, verified status authority or direct order link")
        do {
            _ = try await referenceService.status(orderID: foundReference, credential: "offline", account: "legacy-scope", validateAuthorization: {})
            preconditionFailure("Human reference gained provider status authority")
        } catch { checks += 1 }
        expect(referenceBackend.calls == 0 && !referenceDiagnostics.snapshot.jsonString.contains(foundReference),
               "Manual references cannot dispatch status HTTP or enter sanitized diagnostics")
        let referenceRestart = PaotuiOrderJournal(url: referencePath, clock: clock)
        expect(referenceRestart.pendingReviews(account: "legacy-scope")[0].reportedOrderReference == foundReference,
               "User-found reference survives restart as separate human evidence")
        try referenceRestart.recordReview(attemptID: referenceAttempt, conclusion: .stillUnknown, reportedOrderReference: " ")
        expect(referenceRestart.pendingReviews(account: "legacy-scope")[0].reportedOrderReference == foundReference,
               "A later report without a reference preserves the latest available prior human reference")
        let beforeFailedReference = try Data(contentsOf: referencePath)
        let failedReference = PaotuiOrderJournal(url: referencePath, clock: clock, commit: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        rejects("Failed valid-reference write cannot publish review evidence or resolve unknowns") {
            try failedReference.recordReview(attemptID: referenceAttempt, conclusion: .believesCreated, reportedOrderReference: "MT-20261026-NEW002")
        }
        try expect(Data(contentsOf: referencePath) == beforeFailedReference && failedReference.hasUnresolvedSubmission &&
                   failedReference.pendingReviews(account: "legacy-scope")[0].reportedOrderReference == foundReference,
                   "Failed reference persistence preserves prior bytes, reference and barrier")
        try referenceRestart.recordReview(attemptID: referenceAttempt, conclusion: .believesCreated, reportedOrderReference: "MT-20261026-FINAL003")
        try expect(referenceRestart.archiveResolved() == 1 && referenceRestart.lastOrderID(account: "legacy-scope") == nil &&
                   !referenceRestart.knowsCreatedOrder(orderID: "MT-20261026-FINAL003", account: "legacy-scope") &&
                   referenceRestart.orderURL(quoteID: referenceQuoteID, account: "legacy-scope")?.absoluteString == "https://i.meituan.com/",
                   "Resolved and archived human beliefs with references still never become provider receipts")
        let referencePage = try pages(referencePath)[0]
        let referenceReviews = try rows(referencePage)[0]["reviews"] as! [[String: Any]]
        expect(referenceReviews.count == 4 && referenceReviews[0]["reportedOrderReference"] == nil &&
               referenceReviews[1]["reportedOrderReference"] as? String == foundReference &&
               referenceReviews[3]["reportedOrderReference"] as? String == "MT-20261026-FINAL003",
               "Archive retains every old and new human report, including available references, separately from provider ID")
        let archivedReferenceRestart = PaotuiOrderJournal(url: referencePath, clock: clock)
        expect(archivedReferenceRestart.isReadable && archivedReferenceRestart.maintenanceSnapshot.archivedReceiptCount == 1 &&
               !archivedReferenceRestart.knowsCreatedOrder(orderID: foundReference, account: "legacy-scope"),
               "Archived user evidence survives restart without acquiring provider authority")

        let malformedReferencePath = directory.appendingPathComponent("malformed-human-reference.json")
        var malformedReference = try JSONSerialization.jsonObject(with: beforeFailedReference) as! [String: Any]
        var malformedRows = malformedReference["receipts"] as! [[String: Any]]
        var malformedReviews = malformedRows[0]["reviews"] as! [[String: Any]]
        malformedReviews[1]["reportedOrderReference"] = "https://npay.meituan.com/?pay_token=secret"
        malformedRows[0]["reviews"] = malformedReviews; malformedReference["receipts"] = malformedRows
        let malformedReferenceBytes = try bytes(malformedReference)
        try malformedReferenceBytes.write(to: malformedReferencePath)
        let malformedReferenceJournal = PaotuiOrderJournal(url: malformedReferencePath, clock: clock)
        try expect(!malformedReferenceJournal.isReadable && malformedReferenceJournal.hasUnresolvedSubmission &&
                   Data(contentsOf: malformedReferencePath) == malformedReferenceBytes,
                   "Malformed stored human-reference material fails closed and retains original bytes")

        // Every invalid archive is retained unchanged and closes the entire
        // journal. Conflicts are rejected even when a checksum is recomputed.
        for mode in ["corrupt", "changedFact", "recomputedFact", "future", "oversized", "unexpected", "deletedPage", "deletedDirectory", "unknownArchived", "conflictingPrimary", "conflictingArchive", "duplicatePageID", "identicalDuplicate"] {
            let invalidPath = directory.appendingPathComponent(mode + ".json")
            try seed(invalidPath, [row(1)])
            let source = PaotuiOrderJournal(url: invalidPath, clock: clock)
            try source.archiveResolved()
            let pagePath = try pages(invalidPath)[0]
            var pageObject = try object(pagePath)
            switch mode {
            case "corrupt": try Data("invalid".utf8).write(to: pagePath)
            case "changedFact":
                var values = pageObject["receipts"] as! [[String: Any]]; values[0]["orderID"] = "tampered-order"; pageObject["receipts"] = values
                try bytes(pageObject).write(to: pagePath)
            case "recomputedFact":
                var values = pageObject["receipts"] as! [[String: Any]]; values[0]["orderID"] = "tampered-with-recomputed-checksum"
                pageObject["receipts"] = values; pageObject["sha256"] = try digest(values)
                try bytes(pageObject).write(to: pagePath)
            case "future": pageObject["schemaVersion"] = 99; try bytes(pageObject).write(to: pagePath)
            case "deletedPage": try FileManager.default.removeItem(at: pagePath)
            case "deletedDirectory": try FileManager.default.removeItem(at: pagePath.deletingLastPathComponent())
            case "unknownArchived":
                var values = pageObject["receipts"] as! [[String: Any]]; values[0]["state"] = "unknown"; values[0].removeValue(forKey: "orderID")
                pageObject["receipts"] = values; pageObject["sha256"] = try digest(values)
                try bytes(pageObject).write(to: pagePath)
            case "oversized": try Data(repeating: 32, count: 2_000_001).write(to: pagePath)
            case "unexpected": try Data("unknown future page".utf8).write(to: invalidPath.appendingPathExtension("archive").appendingPathComponent("future.data"))
            case "conflictingPrimary":
                var values = pageObject["receipts"] as! [[String: Any]]; values[0]["orderID"] = "conflicting-provider-fact"
                try seed(invalidPath, values, version: 3)
            case "conflictingArchive", "duplicatePageID", "identicalDuplicate":
                let pageID = mode == "duplicatePageID" ? UUID(uuidString: pageObject["pageID"] as! String)! : UUID(); pageObject["pageID"] = pageID.uuidString; pageObject["pageNumber"] = 2
                var values = pageObject["receipts"] as! [[String: Any]]
                if mode == "conflictingArchive" { values[0]["orderID"] = "conflicting-provider-fact" }
                pageObject["receipts"] = values; pageObject["sha256"] = try digest(values)
                let duplicate = pagePath.deletingLastPathComponent().appendingPathComponent("00000002-" + pageID.uuidString + ".json")
                try bytes(pageObject).write(to: duplicate)
            default: preconditionFailure("Invalid fixture mode")
            }
            let primaryBefore = try Data(contentsOf: invalidPath), archiveBefore = try? Data(contentsOf: pagePath)
            let candidate = PaotuiOrderJournal(url: invalidPath, clock: clock)
            if mode == "identicalDuplicate" {
                expect(candidate.isReadable && candidate.maintenanceSnapshot.archivedReceiptCount == 1 &&
                       candidate.maintenanceSnapshot.archivePageCount == 2 && candidate.lastOrderID(account: "legacy-scope") == "legacy-order-1",
                       "Identical duplicate archived facts deduplicate once by complete attempt equality")
            } else {
                expect(!candidate.isReadable && candidate.hasUnresolvedSubmission && !candidate.maintenanceSnapshot.canArchive &&
                       candidate.lastOrderID(account: "legacy-scope") == nil && !candidate.knowsCreatedOrder(orderID: "legacy-order-1", account: "legacy-scope"),
                       "Invalid, future or conflicting archive fails closed: " + mode)
                rejects("Invalid archive cannot accept new writes: " + mode) { _ = try candidate.beginAttempt(quote: quote("legacy-scope"), account: "legacy-scope") }
                rejects("Invalid archive cannot be overwritten by maintenance: " + mode) { _ = try candidate.archiveResolved() }
                try expect(Data(contentsOf: invalidPath) == primaryBefore && (try? Data(contentsOf: pagePath)) == archiveBefore,
                           "Rejected archive/primary bytes remain intact: " + mode)
            }
        }
        print("PASS: \(checks) actual-source archive/capacity/correlation/fault checks; offline synthetic data, no device/network/orders")
    }
}
