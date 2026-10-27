import Foundation

@MainActor @main private struct PaotuiDiagnosticsChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        checks += 1; precondition(value, label)
    }
    static func rejects(_ object: [String: Any], _ label: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do { _ = try JSONDecoder().decode(PaotuiDiagnosticsSnapshot.self, from: data); preconditionFailure(label) }
        catch { checks += 1 }
    }

    static func main() throws {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaotuiClock(now: { time })
        let recorder = PaotuiDiagnostics(clock: clock, capacity: 4)
        let conversation = UUID(), session = UUID(), quote = UUID(), attempt = UUID(), epoch = UUID()
        let context = PaotuiDiagnosticContext(conversationID: conversation, sessionID: session,
            revision: 7, quoteID: quote, credentialEpoch: epoch)
        let span = recorder.start(command: .submitOrder, phase: .submitting, context: context)!
        expect(recorder.snapshot.activeOperationCount == 1 && recorder.snapshot.events.count == 1, "Start retains one typed event and one bounded operation")
        time.addTimeInterval(1.234)
        expect(recorder.finish(span, result: .created, context: .init(attemptID: attempt)), "Completion may add its persisted attempt identifier")
        let complete = recorder.snapshot.events.last!
        expect(complete.context == .init(conversationID: conversation, sessionID: session, revision: 7,
            quoteID: quote, attemptID: attempt, credentialEpoch: epoch), "Every completion preserves conversation, Session, revision, quote, attempt and credential epoch")
        expect((1_233...1_234).contains(complete.durationMilliseconds ?? 0), "Elapsed milliseconds use the injected clock")
        expect(complete.timestampMilliseconds == 1_800_000_001_234, "Event timestamp uses injected time")
        expect(recorder.snapshot.generatedAtMilliseconds == complete.timestampMilliseconds, "Snapshot uses injected time")
        expect(recorder.snapshot.activeOperationCount == 0 && !recorder.finish(span, result: .created), "Finishing twice cannot duplicate events")

        let task = UUID(), invocation = UUID()
        let taskContext = PaotuiDiagnosticContext(sessionID: UUID(), revision: 0, credentialEpoch: epoch,
            taskID: task, invocationID: invocation)
        expect(recorder.record(command: .toolQuery, phase: .reading, result: .succeeded, context: taskContext), "Tools preserve typed task and invocation origin")
        expect(recorder.snapshot.events.last?.context.taskID == task && recorder.snapshot.events.last?.context.invocationID == invocation, "Task correlation is retained exactly")
        let beforeInvalid = recorder.snapshot.events
        for context in [PaotuiDiagnosticContext(revision: 1), .init(invocationID: UUID()), .init(conversationID: UUID(), taskID: UUID())] {
            expect(!recorder.record(command: .toolQuery, phase: .reading, result: .failed, context: context), "Structurally invalid context is rejected")
        }
        expect(!recorder.record(command: .requestQuote, phase: .reading, result: .started, durationMilliseconds: 1), "Started events cannot claim completed durations")
        expect(!recorder.record(command: .requestQuote, phase: .reading, result: .failed,
            durationMilliseconds: PaotuiDiagnostics.maximumDurationMilliseconds + 1), "Unbounded durations are rejected")
        expect(recorder.snapshot.events == beforeInvalid, "Invalid events leave diagnostics unchanged")

        let protected = recorder.start(command: .readAddresses, phase: .reading, context: context)!
        expect(!recorder.finish(protected, result: .succeeded, context: .init(conversationID: UUID())), "A late completion cannot rewrite its originating conversation")
        expect(!recorder.finish(protected, result: .started), "Completion requires a terminal classification")
        time.addTimeInterval(-100)
        expect(recorder.finish(protected, result: .cancelled), "Clock rollback still permits typed completion")
        expect(recorder.snapshot.events.last?.durationMilliseconds == 0, "A backward clock never records negative duration")
        let long = recorder.start(command: .readPlaces, phase: .reading)!
        time.addTimeInterval(1_000_000)
        expect(recorder.finish(long, result: .failed), "Long operations still settle")
        expect(recorder.snapshot.events.last?.durationMilliseconds == PaotuiDiagnostics.maximumDurationMilliseconds, "Elapsed duration is bounded")
        for revision in 0..<20 {
            expect(recorder.record(command: .updatePreparation, phase: .collecting, result: .succeeded,
                context: .init(sessionID: session, revision: UInt64(revision))), "Bounded stream accepts typed events")
        }
        expect(recorder.snapshot.events.count == 4 && recorder.snapshot.events.first?.context.revision == 16,
            "Capacity retains only the latest events")
        expect(recorder.snapshot.droppedEventCount == 23, "Snapshot counts dropped entries without storing discarded data")
        expect(PaotuiDiagnostics(capacity: 0).capacity == 1 && PaotuiDiagnostics(capacity: Int.max).capacity == 512, "Caller capacity is constrained")
        let boundedSpans = PaotuiDiagnostics(clock: clock, capacity: 1)
        let one = boundedSpans.start(command: .readStatus, phase: .reading)!
        expect(boundedSpans.start(command: .readStatus, phase: .reading) == nil, "Outstanding span state is bounded too")
        expect(boundedSpans.finish(one, result: .succeeded) && boundedSpans.start(command: .readStatus, phase: .reading) != nil,
            "Completion releases span capacity")

        let safe = PaotuiDiagnostics(clock: clock)
        _ = safe.record(command: .submitOrder, phase: .outcome, result: .outcomeUnknown,
            context: .init(conversationID: conversation, sessionID: session, revision: UInt64.max,
                quoteID: quote, attemptID: attempt, credentialEpoch: epoch))
        let safeJSON = safe.snapshot.jsonString
        let restored = try JSONDecoder().decode(PaotuiDiagnosticsSnapshot.self, from: Data(safeJSON.utf8))
        expect(restored == safe.snapshot, "Actual production snapshot round-trips without lossy correlation")
        let unsafeSamples = ["13800138000", "北京市朝阳区测试路88号", "买鸡肉饭", "fixture-private-token", "Authorization", "credentialFingerprint", "requestBody", "hash"]
        for secret in unsafeSamples { expect(!safeJSON.contains(secret), "Safe diagnostic output has no credential, hash, contact, address, goods or payload fields") }
        let allowedRoot: Set<String> = ["schemaVersion", "capacity", "droppedEventCount", "activeOperationCount", "generatedAtMilliseconds", "events"]
        expect(Set(safe.snapshot.jsonObject.keys) == allowedRoot, "Safe snapshot exports only the schema allow-list")
        let event = (safe.snapshot.jsonObject["events"] as! [[String: Any]])[0]
        expect(Set(event.keys) == ["id", "timestampMilliseconds", "command", "phase", "result", "context"], "Event fields are enums, typed correlation and numeric time only")
        let eventContext = event["context"] as! [String: Any]
        expect(eventContext["revision"] is NSNumber && eventContext["conversationID"] as? String == conversation.uuidString,
            "Revision remains numeric and identifiers retain UUID encoding")
        for name in ["conversationID", "sessionID", "quoteID", "attemptID", "credentialEpoch"] {
            expect(UUID(uuidString: eventContext[name] as! String) != nil, "Every string identifier decodes as a UUID")
        }
        var bad = safe.snapshot.jsonObject
        var badEvents = bad["events"] as! [[String: Any]]
        badEvents[0]["command"] = "fixture-private-token"; bad["events"] = badEvents
        try rejects(bad, "Unknown commands cannot be decoded")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badEvents[0]["phase"] = "13800138000"; bad["events"] = badEvents
        try rejects(bad, "Unknown phases cannot be decoded")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badEvents[0]["result"] = "北京市朝阳区测试路88号"; bad["events"] = badEvents
        try rejects(bad, "Unknown results cannot be decoded")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        var badContext = badEvents[0]["context"] as! [String: Any]
        badContext["conversationID"] = "fixture-private-token"; badEvents[0]["context"] = badContext; bad["events"] = badEvents
        try rejects(bad, "An arbitrary string cannot masquerade as an identifier")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badEvents[0]["durationMilliseconds"] = -1; bad["events"] = badEvents
        try rejects(bad, "Negative durations cannot be decoded")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badEvents[0]["durationMilliseconds"] = 1; badEvents[0]["result"] = "started"; bad["events"] = badEvents
        try rejects(bad, "Decoded started events cannot claim completed duration")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badEvents[0]["durationMilliseconds"] = PaotuiDiagnostics.maximumDurationMilliseconds + 1; bad["events"] = badEvents
        try rejects(bad, "Decoded durations are bounded too")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badContext = badEvents[0]["context"] as! [String: Any]
        badContext.removeValue(forKey: "sessionID"); badEvents[0]["context"] = badContext; bad["events"] = badEvents
        try rejects(bad, "A decoded revision requires a Session identifier")
        bad = safe.snapshot.jsonObject; badEvents = bad["events"] as! [[String: Any]]
        badContext = badEvents[0]["context"] as! [String: Any]
        badContext["invocationID"] = UUID().uuidString; badEvents[0]["context"] = badContext; bad["events"] = badEvents
        try rejects(bad, "A decoded invocation requires a task identifier")
        bad = safe.snapshot.jsonObject; bad["capacity"] = 0
        try rejects(bad, "Invalid snapshot capacity cannot be decoded")
        bad = safe.snapshot.jsonObject; bad["schemaVersion"] = 2
        try rejects(bad, "Unknown snapshot schema cannot be decoded")
        bad = safe.snapshot.jsonObject; bad["activeOperationCount"] = 129
        try rejects(bad, "Decoded active operation state is bounded")
        bad = safe.snapshot.jsonObject; bad["capacity"] = 1; bad["events"] = [event, event]
        try rejects(bad, "Decoded event arrays obey declared capacity")
        var injected = safe.snapshot.jsonObject
        injected["rawCredential"] = "fixture-private-token"
        let cleaned = try JSONDecoder().decode(PaotuiDiagnosticsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: injected))
        expect(!cleaned.jsonString.contains("fixture-private-token") && !cleaned.jsonString.contains("rawCredential"),
            "Unrecognized external fields never enter a re-exported snapshot")
        let invalidClock = PaotuiDiagnostics(clock: PaotuiClock(now: { Date(timeIntervalSince1970: .infinity) }))
        expect(invalidClock.record(command: .readStatus, phase: .reading, result: .failed) && invalidClock.snapshot.events[0].timestampMilliseconds == 0,
            "Non-finite wall-clock values cannot enter diagnostic JSON")
        let negativeClock = PaotuiDiagnostics(clock: PaotuiClock(now: { Date(timeIntervalSince1970: -1) }))
        expect(negativeClock.snapshot.generatedAtMilliseconds == 0, "Pre-epoch timestamps remain bounded numeric values")
        let farClock = PaotuiDiagnostics(clock: PaotuiClock(now: { Date(timeIntervalSince1970: 1e20) }))
        expect(farClock.snapshot.generatedAtMilliseconds == 9_007_199_254_740_991, "Future timestamps remain precision-safe JSON integers")
        print("PASS: \(checks) actual-source bounded safe diagnostics checks; offline only")
    }
}
