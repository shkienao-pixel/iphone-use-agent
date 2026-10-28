import Foundation

@main struct Checks {
    static func main() {
        let task = UUID(), session = UUID(), connection = UUID(), generation = UUID(), capture = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        let binding = TaskCheckpointBinding(taskID: task, sessionID: session, goalDigest: "digest", selectedDeviceID: "accessory", connectionGeneration: connection, runtimeGeneration: generation)
        func current(_ b: TaskCheckpointBinding? = nil, active: Bool? = true, running: Bool? = true, ready: Bool? = true, matches: Bool? = true, pending: Bool? = false) -> TaskCheckpointCurrent {
            .init(binding: b ?? binding, runActive: active, captureRunning: running, accessoryReady: ready, currentFrameMatches: matches, pendingReview: pending)
        }
        func fact(scene: String = "search", source: TaskCheckpointSource = .alreadyVisible, scope: TaskCheckpointVerificationScope = .systemSearchVerified, id: UUID? = capture, captured: Date = base, confirmed: Date? = nil, boundary: Date? = nil, full: Bool = true, blocked: Bool = false, accessory: String? = "accessory", conn: UUID = connection, gen: UUID = generation) -> TaskCheckpointFact {
            .init(scene: scene, source: source, verificationScope: scope, captureID: id, capturedAt: captured, confirmedAt: confirmed ?? captured, inputCompletedAt: boundary, fullDisplay: full, blockingOverlay: blocked, selectedDeviceID: accessory, connectionGeneration: conn, runtimeGeneration: gen)
        }
        var count = 0
        func check(_ name: String, _ expected: TaskCheckpointVerdict, _ f: TaskCheckpointFact? = nil, _ b: TaskCheckpointBinding? = nil, _ c: TaskCheckpointCurrent? = nil, condition: TaskCheckpointCondition? = .systemSearchVisible) {
            let d = TaskCheckpointPolicy.evaluate(condition: condition, fact: f ?? fact(), binding: b ?? binding, current: c ?? current())
            precondition(d.verdict == expected, "\(name): expected \(expected), got \(d.verdict) \(d.reason)")
            count += 1
        }
        check("already visible", .pass)
        check("already visible with input", .unknown, fact(boundary: base))
        check("post-input fresh pixels", .pass, fact(source: .afterInput, captured: base.addingTimeInterval(2), boundary: base))
        check("old pixels after new confirmation", .unknown, fact(source: .afterInput, confirmed: base.addingTimeInterval(2), boundary: base))
        check("missing input boundary", .unknown, fact(source: .afterInput))
        check("search scene ambiguous", .unknown, fact(scope: .searchSceneOnly))
        check("desktop", .fail, fact(scene: "home"))
        check("other app search ambiguous", .unknown, fact(scope: .searchSceneOnly))
        check("unknown scene", .unknown, fact(scene: "unknown"))
        check("overlay", .unknown, fact(blocked: true))
        check("partial frame", .unknown, fact(full: false))
        check("missing capture", .unknown, fact(id: nil))
        check("stale frame", .unknown, nil, nil, current(matches: false))
        check("frame validity unavailable", .unknown, nil, nil, current(matches: nil))
        check("capture running unavailable", .unknown, nil, nil, current(running: nil))
        check("pause or stop", .unknown, nil, nil, current(active: false))
        check("sharing stopped", .unknown, nil, nil, current(running: false))
        check("accessory disconnected", .unknown, nil, nil, current(ready: false))
        check("rotation or changed screen", .unknown, nil, nil, current(matches: false))
        check("pending blocks", .unknown, nil, nil, current(pending: true))
        check("unknown pending", .unknown, nil, nil, current(pending: nil))
        check("condition missing", .unknown, condition: nil)
        let otherTask = TaskCheckpointBinding(taskID: UUID(), sessionID: session, goalDigest: "digest", selectedDeviceID: "accessory", connectionGeneration: connection, runtimeGeneration: generation)
        let otherSession = TaskCheckpointBinding(taskID: task, sessionID: UUID(), goalDigest: "digest", selectedDeviceID: "accessory", connectionGeneration: connection, runtimeGeneration: generation)
        let otherGoal = TaskCheckpointBinding(taskID: task, sessionID: session, goalDigest: "changed", selectedDeviceID: "accessory", connectionGeneration: connection, runtimeGeneration: generation)
        let otherConnection = TaskCheckpointBinding(taskID: task, sessionID: session, goalDigest: "digest", selectedDeviceID: "accessory", connectionGeneration: UUID(), runtimeGeneration: generation)
        for (name, b) in [("task switched", otherTask), ("session changed", otherSession), ("goal changed", otherGoal), ("reconnected", otherConnection)] { check(name, .unknown, nil, nil, current(b)) }
        check("stale runtime", .unknown, fact(gen: UUID()))
        check("changed accessory", .unknown, fact(accessory: "other"))
        check("infinite capture time", .unknown, fact(captured: Date(timeIntervalSinceReferenceDate: .infinity)))
        check("confirmation before pixels", .unknown, fact(confirmed: base.addingTimeInterval(-1)))
        let missingBinding = TaskCheckpointPolicy.evaluate(condition: .systemSearchVisible, fact: fact(), binding: nil, current: current())
        precondition(missingBinding.verdict == .unknown && missingBinding.reason == "evidence_missing")
        let missingCurrent = TaskCheckpointPolicy.evaluate(condition: .systemSearchVisible, fact: fact(), binding: binding, current: nil)
        precondition(missingCurrent.verdict == .unknown && missingCurrent.reason == "evidence_missing")
        count += 2
        let noFact = TaskCheckpointPolicy.evaluate(condition: .systemSearchVisible, fact: nil, binding: binding, current: current())
        precondition(noFact.verdict == .unknown && noFact.reason == "evidence_missing")
        count += 1
        print("TaskCheckpointPolicy: \(count) offline cases passed")
    }
}
