import Foundation

final class FaultWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func fail(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func write(_ data: Data, _ url: URL) throws {
        lock.lock(); let fail = failing; lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fail {
            // A simulated crash leaves an incomplete staging file; the previous
            // authoritative file remains byte-for-byte intact.
            try Data(data.prefix(31)).write(to: url.appendingPathExtension("staging"))
            throw ReadOnlyWorkflowLedgerError.unavailable
        }
        try data.write(to: url, options: .atomic)
    }
}

actor SimulatedTransport {
    private(set) var requests: [ReadOnlyWorkflowLease] = []
    func run(_ ledger: ReadOnlyWorkflowLedger, context: ReadOnlyWorkflowContext,
             response: ReadOnlyWorkflowResponse, now: Date) async throws -> ReadOnlyWorkflowLease? {
        guard let lease = try await ledger.leaseNext(context: context, now: now) else { return nil }
        guard try await ledger.request(for: lease, context: context, now: now) != nil else { fatalError("No committed request for lease") }
        requests.append(lease)
        _ = try await ledger.receive(lease: lease, response: response, context: context, now: now)
        return lease
    }
}

@main struct ReadOnlyWorkflowChecks {
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func expectError(_ operation: () async throws -> Void, _ expected: ReadOnlyWorkflowLedgerError, _ label: String) async {
            do { try await operation(); fatalError(label) }
            catch { expect((error as? ReadOnlyWorkflowLedgerError) == expected, label) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 10_000), deadline = Date(timeIntervalSince1970: 10_600)
        let conversation = UUID(), message = UUID(), otherConversation = UUID(), otherMessage = UUID()
        let configuration = ReadOnlyWorkflowConfiguration(endpoint: "https://provider.invalid/chat/completions", recipient: "Original Provider",
            model: "offline-model", credentialGeneration: UUID(), consentGeneration: UUID(), memoryRevision: "memory-1", flightConnectionGeneration: UUID())
        let scope = configuration.fingerprint
        let sourceDigest = ReadOnlyWorkflowRequest(stage: .routing, question: "immutable submitted source").fingerprint
        let context = ReadOnlyWorkflowContext(configurationFingerprint: scope,
            sourceMessages: [conversation: [message], otherConversation: [otherMessage]], sourceFingerprints: [message: sourceDigest, otherMessage: sourceDigest])
        var changed = configuration; changed.recipient = "Different Provider"
        expect(changed.fingerprint != scope && scope.count == 64, "Recipient change creates a different immutable configuration fingerprint")
        changed = configuration; changed.credentialGeneration = UUID()
        expect(changed.fingerprint != scope, "Replacing a key invalidates old work without storing the key")
        changed = configuration; changed.consentGeneration = UUID()
        expect(changed.fingerprint != scope, "Revoking and regranting the same endpoint cannot revive old authorization")
        changed = configuration; changed.usesMemories = false
        expect(changed.fingerprint != scope, "Disabling memory invalidates work carrying its earlier recalled content")
        changed = configuration; changed.memoryRevision = "memory-2"
        expect(changed.fingerprint != scope, "A new recall revision invalidates historical inputs")

        let url = folder.appendingPathComponent("workflow.json")
        let initial = ReadOnlyWorkflowRequest(stage: .routing, question: "查明天深圳到北京的航班", references: "仅为离线参考")
        var ledger = try ReadOnlyWorkflowLedger(url: url, maximumConcurrent: 2)
        let job = try await ledger.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: initial, deadline: deadline, now: now)
        let same = try await ledger.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: initial, deadline: deadline, now: now)
        expect(job.id == same.id && job.replyID == same.replyID, "Submitting the same saved message twice returns its first durable identity")
        let lease = try await ledger.leaseNext(context: context, now: now)!
        expect(lease.stage == .routing && lease.attempt == 1, "Only the first read-only stage dispatches initially")
        ledger = try ReadOnlyWorkflowLedger(url: url, maximumConcurrent: 2)
        let restored = try await ledger.reconcile(activeLeaseIDs: [lease.id], context: context, now: now)
        expect(restored[0].lease == lease && restored[0].state == .transferring, "Reopening reattaches an exact existing transfer rather than creating another")
        expect(try await ledger.receive(lease: lease, response: .route(.flightQuery(question: "2026-10-27 深圳到北京 一成人")), context: context, now: now) == .applied,
               "A committed routing receipt can advance to a bounded flight query")
        expect(try await ledger.receive(lease: lease, response: .route(.flightQuery(question: "2026-10-27 深圳到北京 一成人")), context: context, now: now) == .duplicate,
               "Repeated routing receipt cannot create a second provider query")
        expect(try await ledger.receive(lease: lease, response: .route(.answer(question: "other answer")), context: context, now: now) == .conflicting,
               "A contradictory receipt for the same lease cannot replace its accepted transition")
        let duplicateAfterRoute = try await ledger.submit(conversationID: conversation, userMessageID: message,
            configurationFingerprint: scope, sourceFingerprint: sourceDigest, request: initial, deadline: deadline, now: now)
        expect(duplicateAfterRoute.id == job.id, "Crash retry still matches the original submission after its current stage changes")
        await expectError({ _ = try await ledger.submit(conversationID: conversation, userMessageID: message,
            configurationFingerprint: scope, request: .init(stage: .routing, question: "different original"), deadline: deadline, now: now) }, .submissionConflict,
            "The same message ID cannot be repurposed for a different request after routing")
        let transport = SimulatedTransport()
        let flightLease = try await transport.run(ledger, context: context, response: .text("离线模拟回执：HU7712 450元；并非实时查询"), now: now)!
        expect(flightLease.stage == .flightQuery && flightLease.id != lease.id && flightLease.generation != lease.generation,
               "The second stage has a fresh exact request identity")
        var publications = try await ledger.pendingPublications(context: context, now: now)
        expect(publications.count == 1 && publications[0].conversationID == conversation && publications[0].userMessageID == message,
               "Result publication belongs to the original conversation and user message")
        let publication = publications[0]
        var savedConversationReplies: [UUID: String] = [publication.replyID: publication.text]
        // Crash after conversation save, before workflow acknowledgement.
        ledger = try ReadOnlyWorkflowLedger(url: url)
        publications = try await ledger.pendingPublications(context: context, now: now)
        savedConversationReplies[publications[0].replyID] = publications[0].text
        expect(savedConversationReplies.count == 1 && publications[0] == publication, "Crash replay publishes the same replyID and text without adding a second answer")
        expect(try await ledger.acknowledgePublished(publication, context: context, now: now), "A durable conversation save can acknowledge the exact publication")
        expect(try await ledger.acknowledgePublished(publication, context: context, now: now), "A repeated publication acknowledgement is idempotent")
        expect(try await ledger.pendingPublications(context: context, now: now).isEmpty, "Acknowledged answers leave the pending outbox")
        expect(try await ledger.receive(lease: flightLease, response: .text(publication.text), context: context, now: now) == .duplicate,
               "A repeated final transport callback is deduplicated after publication")
        let encoded = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        expect(!encoded.contains(configuration.endpoint) && !encoded.contains(configuration.recipient), "Ledger stores only the configuration fingerprint, never recipient or endpoint details")

        // An action route is preserved for review and can never enter retry.
        let actionLedger = try ReadOnlyWorkflowLedger(url: folder.appendingPathComponent("action.json"))
        _ = try await actionLedger.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: initial, deadline: deadline, now: now)
        let actionLease = try await actionLedger.leaseNext(context: context, now: now)!
        expect(try await actionLedger.receive(lease: actionLease, response: .text("I did an action"), context: context, now: now) == .rejected,
               "A routing stage cannot turn arbitrary text into a completed answer or action receipt")
        expect(try await actionLedger.jobs()[0].failure == .invalidResponse, "Malformed terminal receipts release their dispatch slot into an explicit review state")
        let foregroundJob = try await actionLedger.submit(conversationID: otherConversation, userMessageID: otherMessage,
            configurationFingerprint: scope, sourceFingerprint: sourceDigest, request: initial, deadline: deadline, now: now)
        let foregroundLease = try await actionLedger.leaseNext(context: context, now: now)!
        _ = try await actionLedger.receive(lease: foregroundLease, response: .route(.requiresForeground), context: context, now: now)
        expect(try await actionLedger.jobs().first(where: { $0.id == foregroundJob.id })?.failure == .foregroundActionRequired,
               "Actions become an explicit foreground-review checkpoint")
        expect(try await !actionLedger.retry(foregroundJob.id, context: context, now: now), "Recovery never automatically dispatches a side-effect route")

        // Missing transfers, bounded explicit retries, and stale old callbacks.
        let retryURL = folder.appendingPathComponent("retry.json")
        var retryLedger = try ReadOnlyWorkflowLedger(url: retryURL)
        let answerJob = try await retryLedger.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: .init(stage: .answer, question: "offline question"), deadline: deadline, now: now)
        let missingLease = try await retryLedger.leaseNext(context: context, now: now)!
        retryLedger = try ReadOnlyWorkflowLedger(url: retryURL)
        _ = try await retryLedger.reconcile(activeLeaseIDs: [], context: context, now: now)
        let missingSnapshot = try await retryLedger.jobs()[0]
        expect(missingSnapshot.state == .needsForeground && missingSnapshot.failure == .transferMissing,
               "A transfer absent after restart remains visible instead of being dropped or silently resent")
        expect(try await retryLedger.leaseNext(context: context, now: now) == nil, "Relaunch cannot silently replace an unknown missing network transfer")
        expect(try await retryLedger.retry(answerJob.id, context: context, now: now), "The caller can explicitly continue a read-only missing-transfer checkpoint")
        let retryLease = try await retryLedger.leaseNext(context: context, now: now)!
        expect(retryLease.attempt == 2 && retryLease.generation != missingLease.generation, "Retry consumes the same bounded stage budget with fresh authority")
        expect(try await retryLedger.receive(lease: missingLease, response: .text("late obsolete answer"), context: context, now: now) == .stale,
               "A response from the lost first attempt cannot settle its replacement")
        _ = try await retryLedger.receive(lease: retryLease, response: .failure(.network), context: context, now: now)
        expect(try await !retryLedger.retry(answerJob.id, context: context, now: now), "The read-only stage cannot exceed its two host-dispatch attempts")

        // Global dispatch slots and cancellation tombstones survive restart.
        let concurrentURL = folder.appendingPathComponent("concurrent.json")
        var concurrent = try ReadOnlyWorkflowLedger(url: concurrentURL, maximumConcurrent: 2)
        let ids = (0..<3).map { _ in UUID() }
        let concurrentContext = ReadOnlyWorkflowContext(configurationFingerprint: scope, sourceMessages: [conversation: Set(ids)], sourceFingerprints: Dictionary(uniqueKeysWithValues: ids.map { ($0, ReadOnlyWorkflowRequest(stage: .answer, question: $0.uuidString).fingerprint) }))
        for id in ids { _ = try await concurrent.submit(conversationID: conversation, userMessageID: id, configurationFingerprint: scope,
            request: .init(stage: .answer, question: id.uuidString), deadline: deadline, now: now) }
        let concurrentFirst = try await concurrent.leaseNext(context: concurrentContext, now: now)!
        _ = try await concurrent.leaseNext(context: concurrentContext, now: now)!
        expect(try await concurrent.leaseNext(context: concurrentContext, now: now) == nil, "Maximum concurrent leases are enforced independently of queued count")
        expect(try await concurrent.cancel(concurrentFirst.jobID, now: now), "Cancellation commits a durable tombstone")
        concurrent = try ReadOnlyWorkflowLedger(url: concurrentURL, maximumConcurrent: 2)
        expect(try await concurrent.receive(lease: concurrentFirst, response: .text("late cancelled response"), context: concurrentContext, now: now) == .stale,
               "A late response after process restart cannot revive a cancelled job")
        expect(try await concurrent.leaseNext(context: concurrentContext, now: now) != nil, "Durable cancellation frees exactly one dispatch slot")
        expect(try await concurrent.cancel(concurrentFirst.jobID, now: now), "Repeated cancellation keeps the same tombstone")

        // Deadlines, recipient switches, deleted source messages and conversations.
        let invalidationURL = folder.appendingPathComponent("invalidation.json")
        var invalidation = try ReadOnlyWorkflowLedger(url: invalidationURL)
        let invalidJob = try await invalidation.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: .init(stage: .answer, question: "private source", references: "private historical excerpts"), deadline: deadline, now: now)
        let invalidLease = try await invalidation.leaseNext(context: context, now: now)!
        var switched = context; switched.configurationFingerprint = changed.fingerprint
        expect(try await invalidation.receive(lease: invalidLease, response: .text("wrong recipient result"), context: switched, now: now) == .stale,
               "A changed recipient/model/key/consent fingerprint rejects an in-flight response")
        let invalidScopeSnapshot = try await invalidation.jobs()[0]
        expect(invalidScopeSnapshot.state == .needsForeground && invalidScopeSnapshot.failure == .scopeChanged,
               "Changed configuration leaves an explicit visible review state")
        expect(try await !invalidation.retry(invalidJob.id, context: context, now: now), "Switching back does not revive the earlier revoked generation")
        var sourceDeleted = context; sourceDeleted.sourceMessages[conversation] = [otherMessage]
        _ = try await invalidation.reconcile(activeLeaseIDs: [], context: sourceDeleted, now: now)
        expect(try await invalidation.jobs()[0].state == .abandoned, "Deleting the submitted message invalidates work even if its conversation remains")
        let sanitized = String(decoding: try Data(contentsOf: invalidationURL), as: UTF8.self)
        expect(!sanitized.contains("private source") && !sanitized.contains("private historical excerpts"), "Deleted source payload is redacted while its non-executable tombstone survives")
        invalidation = try ReadOnlyWorkflowLedger(url: invalidationURL)
        expect(try await invalidation.receive(lease: invalidLease, response: .text("resurrection"), context: context, now: now) == .stale,
               "Readding a source ID cannot revive an abandoned job after restart")
        var noConversation = context; noConversation.sourceMessages = [:]
        _ = try await ledger.reconcile(activeLeaseIDs: [], context: noConversation, now: now)
        let deletedConversationSnapshot = try await ledger.jobs()[0]
        expect(deletedConversationSnapshot.state == .abandoned && deletedConversationSnapshot.resultText == nil,
               "Deleting a conversation also purges a previously completed outbox result")

        let expiry = try ReadOnlyWorkflowLedger(url: folder.appendingPathComponent("expiry.json"))
        _ = try await expiry.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: .init(stage: .answer, question: "expires"), deadline: deadline, now: now)
        let expiredLease = try await expiry.leaseNext(context: context, now: now)!
        expect(try await expiry.receive(lease: expiredLease, response: .text("late after deadline"), context: context, now: deadline) == .stale,
               "The exact deadline invalidates a late transport callback")
        let expiredSnapshot = try await expiry.jobs()[0]
        expect(expiredSnapshot.state == .expired && expiredSnapshot.failure == .deadline, "Expired tasks remain visible instead of silently disappearing")

        // Atomic failure boundaries: no dispatch or publication before durable write.
        let atomicURL = folder.appendingPathComponent("atomic.json"), fault = FaultWriter()
        let atomic = try ReadOnlyWorkflowLedger(url: atomicURL, writer: { try fault.write($0, $1) })
        let atomicJob = try await atomic.submit(conversationID: conversation, userMessageID: message, configurationFingerprint: scope, sourceFingerprint: sourceDigest,
            request: .init(stage: .answer, question: "atomic test"), deadline: deadline, now: now)
        var originalBytes = try Data(contentsOf: atomicURL)
        fault.fail(true)
        await expectError({ _ = try await atomic.leaseNext(context: context, now: now) }, .unavailable, "A failed dispatch checkpoint returns no network lease")
        let dispatchBytes = try Data(contentsOf: atomicURL)
        expect(try await atomic.jobs()[0].state == .queued && dispatchBytes == originalBytes,
               "A torn staging write cannot replace either committed snapshot")
        let reopenedAfterTornWrite = try ReadOnlyWorkflowLedger(url: atomicURL)
        expect(try await reopenedAfterTornWrite.jobs()[0].state == .queued, "Reopening ignores incomplete staging bytes")
        fault.fail(false)
        let atomicLease = try await atomic.leaseNext(context: context, now: now)!
        originalBytes = try Data(contentsOf: atomicURL); fault.fail(true)
        await expectError({ _ = try await atomic.receive(lease: atomicLease, response: .text("not yet committed"), context: context, now: now) }, .unavailable,
            "A failed result save never emits an accepted receipt")
        let failedResultBytes = try Data(contentsOf: atomicURL)
        expect(try await atomic.jobs()[0].state == .transferring && failedResultBytes == originalBytes,
               "Result write failure retains the exact recoverable transfer checkpoint")
        await expectError({ _ = try await atomic.cancel(atomicJob.id, now: now) }, .unavailable, "A cancellation persistence failure is explicit")
        expect(await atomic.pendingCancellationIDs().contains(atomicJob.id), "Cancellation failure retains volatile revocation until saving can be repaired")
        expect(try await atomic.request(for: atomicLease, context: context, now: now) == nil, "Failed cancellation persistence still revokes further in-process dispatch")
        expect(try await atomic.receive(lease: atomicLease, response: .text("late after volatile cancellation"), context: context, now: now) == .stale,
               "A late callback cannot bypass volatile cancellation during storage failure")
        fault.fail(false)
        expect(try await atomic.cancel(atomicJob.id, now: now), "An explicit save retry commits the retained cancellation tombstone")
        expect(await atomic.pendingCancellationIDs().isEmpty, "Successful tombstone save clears the persistence warning")
        expect((try await ReadOnlyWorkflowLedger(url: atomicURL).jobs())[0].state == .cancelled, "Cancellation survives restart once its durable write succeeds")

        // Invalid/future archives are never rewritten as a blank queue.
        let badURL = folder.appendingPathComponent("bad.json")
        let badBytes = Data("{broken".utf8); try badBytes.write(to: badURL)
        do { _ = try ReadOnlyWorkflowLedger(url: badURL); fatalError("Corrupt archive accepted") }
        catch { expect((error as? ReadOnlyWorkflowLedgerError) == .unavailable, "Corrupt archive refuses to open") }
        expect(try Data(contentsOf: badURL) == badBytes, "Corrupt original bytes are preserved")
        var future = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        future["version"] = 2
        let futureBytes = try JSONSerialization.data(withJSONObject: future); try futureBytes.write(to: badURL)
        do { _ = try ReadOnlyWorkflowLedger(url: badURL); fatalError("Future archive accepted") }
        catch { expect((error as? ReadOnlyWorkflowLedgerError) == .unsupportedVersion, "Future archive version refuses to open") }
        expect(try Data(contentsOf: badURL) == futureBytes, "Future schema remains untouched")
        await expectError({ _ = try await ledger.leaseNext(context: .init(configurationFingerprint: "raw endpoint", sourceMessages: [:], sourceFingerprints: [:]), now: now) }, .invalid,
            "An invalid current-scope fingerprint cannot mutate the queue")
        // Multiple instances cannot erase a newer cancellation or overbook work.
        let sharedURL = folder.appendingPathComponent("multi-instance.json")
        let oldOwner = try ReadOnlyWorkflowLedger(url: sharedURL)
        let sharedJob = try await oldOwner.submit(conversationID: conversation, userMessageID: message,
            configurationFingerprint: scope, sourceFingerprint: sourceDigest, request: initial, deadline: deadline, now: now)
        let sharedLease = try await oldOwner.leaseNext(context: context, now: now)!
        let newerOwner = try ReadOnlyWorkflowLedger(url: sharedURL)
        _ = try await newerOwner.cancel(sharedJob.id, now: now)
        expect(try await oldOwner.receive(lease: sharedLease, response: .route(.answer(question: "obsolete instance")), context: context, now: now) == .stale,
               "An old instance refreshes before processing and cannot overwrite another instance's durable cancellation")
        let afterCompetingOwner = try ReadOnlyWorkflowLedger(url: sharedURL)
        expect(try await afterCompetingOwner.jobs()[0].state == .cancelled, "A competing old callback cannot erase the new tombstone on disk")
        expect(try await oldOwner.request(for: sharedLease, context: context, now: now) == nil,
               "Old instances cannot dispatch against a transfer cancelled by another owner")

        let editLedger = try ReadOnlyWorkflowLedger(url: folder.appendingPathComponent("edited-source.json"))
        let editJob = try await editLedger.submit(conversationID: conversation, userMessageID: message,
            configurationFingerprint: scope, sourceFingerprint: sourceDigest, request: initial, deadline: deadline, now: now)
        let editLease = try await editLedger.leaseNext(context: context, now: now)!
        var editedSource = context
        editedSource.sourceFingerprints[message] = ReadOnlyWorkflowRequest(stage: .routing, question: "edited under the same UUID").fingerprint
        expect(try await editLedger.request(for: editLease, context: editedSource, now: now) == nil,
               "Editing content under the same submitted UUID revokes dispatch before network construction")
        expect(try await editLedger.receive(lease: editLease, response: .route(.answer(question: "old content result")), context: editedSource, now: now) == .stale,
               "An edited source cannot accept a late response from its earlier content snapshot")
        expect(try await editLedger.jobs()[0].failure == .sourceChanged, "Source edits remain an explicit review checkpoint")
        expect(try await !editLedger.retry(editJob.id, context: context, now: now), "Restoring old source text does not silently reauthorize its revoked generation")

        let raceURL = folder.appendingPathComponent("dispatch-race.json")
        let racing = try ReadOnlyWorkflowLedger(url: raceURL, maximumConcurrent: 2)
        let raceMessages = (0..<4).map { _ in UUID() }
        let raceContext = ReadOnlyWorkflowContext(configurationFingerprint: scope,
            sourceMessages: [conversation: Set(raceMessages)], sourceFingerprints: Dictionary(uniqueKeysWithValues: raceMessages.map { ($0, sourceDigest) }))
        for sourceID in raceMessages { _ = try await racing.submit(conversationID: conversation, userMessageID: sourceID,
            configurationFingerprint: scope, sourceFingerprint: sourceDigest, request: initial, deadline: deadline, now: now) }
        let racedLeases = try await withThrowingTaskGroup(of: ReadOnlyWorkflowLease?.self) { group in
            for _ in 0..<12 { group.addTask { try await racing.leaseNext(context: raceContext, now: now) } }
            var accepted: [ReadOnlyWorkflowLease] = []
            for try await lease in group { if let lease { accepted.append(lease) } }
            return accepted
        }
        expect(racedLeases.count == 2 && Set(racedLeases.map(\.jobID)).count == 2,
               "Concurrent callers receive at most the configured number of distinct committed dispatch leases")
        expect(try await racing.removeFinished(Set((try await racing.jobs()).map(\.id))) == 0,
               "Explicit terminal cleanup cannot delete queued, transferring or review checkpoints")
        _ = try await oldOwner.removeFinished([sharedJob.id])
        expect(try await oldOwner.jobs().isEmpty, "Explicit terminal-history cleanup relieves the bounded store")
        expect(try await oldOwner.receive(lease: sharedLease, response: .text("removed old callback"), context: context, now: now) == .stale,
               "A callback for explicitly removed terminal history stays stale rather than creating new work")
        // Exercise competing actor instances, not just concurrent calls on one.
        let secondRacer = try ReadOnlyWorkflowLedger(url: raceURL, maximumConcurrent: 2)
        for lease in racedLeases { _ = try await racing.cancel(lease.jobID, now: now) }
        let crossInstanceLeases = try await withThrowingTaskGroup(of: ReadOnlyWorkflowLease?.self) { group in
            for index in 0..<12 {
                let owner = index.isMultiple(of: 2) ? racing : secondRacer
                group.addTask {
                    do { return try await owner.leaseNext(context: raceContext, now: now) }
                    catch ReadOnlyWorkflowLedgerError.storeChanged { return nil }
                }
            }
            var accepted: [ReadOnlyWorkflowLease] = []
            for try await lease in group { if let lease { accepted.append(lease) } }
            return accepted
        }
        expect(crossInstanceLeases.count <= 2 && Set(crossInstanceLeases.map(\.jobID)).count == crossInstanceLeases.count,
               "Competing file-backed actors cannot overwrite leases or exceed the global dispatch limit")
        expect(try await ReadOnlyWorkflowLedger(url: raceURL).jobs().filter { $0.state == .transferring }.count <= 2,
               "Committed file remains within the concurrency limit after competing-instance writes")

        // Corrupt storage cannot prevent in-process cancellation from revoking
        // a known lease, even before a durable tombstone can be saved.
        let refreshURL = folder.appendingPathComponent("cancel-refresh-failure.json")
        let refreshLedger = try ReadOnlyWorkflowLedger(url: refreshURL)
        let refreshJob = try await refreshLedger.submit(conversationID: conversation, userMessageID: message,
            configurationFingerprint: scope, sourceFingerprint: sourceDigest, request: initial, deadline: deadline, now: now)
        let refreshLease = try await refreshLedger.leaseNext(context: context, now: now)!
        let intactBytes = try Data(contentsOf: refreshURL)
        try Data("broken replacement".utf8).write(to: refreshURL, options: .atomic)
        await expectError({ _ = try await refreshLedger.cancel(refreshJob.id, now: now) }, .unavailable,
            "Cancellation reports a failed refresh instead of silently losing its revocation")
        try intactBytes.write(to: refreshURL, options: .atomic)
        expect(try await refreshLedger.request(for: refreshLease, context: context, now: now) == nil,
               "Repairing storage cannot resurrect a lease revoked during failed cancellation refresh")
        expect(try await refreshLedger.receive(lease: refreshLease, response: .route(.answer(question: "late")), context: context, now: now) == .stale,
               "Late callback remains rejected after cancellation refresh failure and repair")
        print("PASS: \(checks) durable read-only workflow, simulated transport, restart, ownership, cancellation and atomic-write checks; no network/model/device calls")
    }
}
