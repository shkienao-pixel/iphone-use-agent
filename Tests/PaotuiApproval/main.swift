import Foundation

@MainActor private final class ApprovalGate {
    var entered = false
    var enteredWaiter: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; enteredWaiter?.resume(); enteredWaiter = nil; await withCheckedContinuation { release = $0 } }
    func wait() async { if !entered { await withCheckedContinuation { enteredWaiter = $0 } } }
    func resume() { release?.resume(); release = nil }
}

@main private struct ApprovalChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
    @MainActor static func reject(_ operation: () async throws -> Void, _ message: String) async {
        do { try await operation(); preconditionFailure(message) } catch { checks += 1 }
    }
    @MainActor static func main() async throws {
        var calls = 0
        await reject({ _ = try await PaotuiInterpretationGate.run(operation: { calls += 1; return "{}" }, isApproved: { false }) }, "Rejected approval dispatched an interpreter")
        expect(calls == 0, "Approval denial happens before the model boundary")
        let accepted = try await PaotuiInterpretationGate.run(operation: { calls += 1; return "valid response" }, isApproved: { true })
        expect(accepted == "valid response" && calls == 1, "The original approval can accept one interpretation")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-approval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for revoked in [false, true] {
            let backend = Backend()
            let store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: root.appendingPathComponent(UUID().uuidString), clientFactory: backend.client)
            try store.installCredential("offline-approval-key")
            let module = PaotuiModule(store: store, conversation: MeituanPaotuiConversation(store: store))
            let id = UUID(), gate = ApprovalGate()
            var approved = true, interpreted = 0
            let result = Task {
                try await module.handle(.text(question: "帮我买水", history: []), context: .init(conversationID: id, requestID: UUID()), interpret: { _, _ in
                    try await PaotuiInterpretationGate.run(operation: {
                        interpreted += 1; await gate.hold()
                        return #"{"service":"buy","goods":"未采用的商品","recipient":"Fixture address 1","nearby":true}"#
                    }, isApproved: { approved })
                })
            }
            await gate.wait()
            if revoked { approved = false } else { result.cancel() }
            gate.resume()
            await reject({ _ = try await result.value }, "A canceled or revoked interpretation reached preparation")
            expect(interpreted == 1, "A late result never triggers another model request")
            let current = store.existingSession(for: id)!
            expect(current.draft.goods.isEmpty && current.currentCard == nil && current.quotes.isEmpty, "Unapproved model output never becomes a draft, card or quote")
            expect(backend.previews.isEmpty && backend.submissions.isEmpty && store.addresses.isEmpty, "Unapproved output cannot trigger phone/book/quote or order operations")
        }
        var inheritedApproved = true
        let beforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PaotuiInterpretationGate.run(operation: { calls += 1; return "must not run" }, isApproved: { inheritedApproved })
        }
        await reject({ _ = try await beforeStart.value }, "A task canceled before approval dispatched an interpreter")
        expect(calls == 1, "Canceled-before-start never crosses the model boundary")
        inheritedApproved = false
        print("PASS: \(checks) actual-source interpretation approval, cancellation and no-unapproved-preparation checks; offline only")
    }
}
