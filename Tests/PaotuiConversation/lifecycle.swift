import Foundation

@MainActor private final class LifecycleGate {
    private var entered = false
    private var blocker: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func block() async {
        entered = true
        observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { blocker = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { blocker?.resume(); blocker = nil }
}

@MainActor private final class LifecycleBackend {
    let fixture = Backend()
    var failingEndpoint: String?
    var gates: [String: LifecycleGate] = [:]
    func client(_ credential: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: credential, transport: { request in
            let endpoint = request.url!.lastPathComponent
            if let gate = self.gates.removeValue(forKey: endpoint) { await gate.block() }
            if self.failingEndpoint == endpoint { throw URLError(.cannotConnectToHost) }
            return try self.fixture.respond(request)
        })
    }
}

@MainActor private final class LifecyclePlanner {
    var value = "{}"
    var calls = 0
    var prompts: [String] = []
    var nextGate: LifecycleGate?
    func extract(_ prompt: String) async -> String {
        calls += 1; prompts.append(prompt)
        let result = value, gate = nextGate
        nextGate = nil
        if let gate { await gate.block() }
        return result
    }
}

@MainActor private final class LifecycleScenario {
    let backend = LifecycleBackend()
    let planner = LifecyclePlanner()
    let receiptURL: URL
    let store: MeituanPaotuiStore
    let controller: MeituanPaotuiConversation
    init(root: URL) throws {
        receiptURL = root.appendingPathComponent(UUID().uuidString + ".json")
        store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: receiptURL, clientFactory: backend.client)
        try store.installCredential("offline-lifecycle-credential")
        let planner = self.planner
        controller = MeituanPaotuiConversation(store: store, planner: { _, prompt, _ in await planner.extract(prompt) })
    }
    func respond(_ id: UUID, plan: [String: Any]) async throws -> PaotuiChatReply {
        planner.value = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        return try await controller.respond(question: "本次跑腿需求", history: [], conversationID: id)
    }
    func request(_ id: UUID, goods: String = "本次水一瓶", merchant: Bool = false, inquiryOnly: Bool = false) async throws -> PaotuiChatReply {
        var plan: [String: Any] = ["service": "buy", "goods": goods, "recipient": "Fixture address 2", "inquiryOnly": inquiryOnly]
        if merchant { plan["store"] = "Fixture Kitchen" } else { plan["nearby"] = true }
        return try await respond(id, plan: plan)
    }
    func choose(_ reply: PaotuiChatReply, _ value: String, _ id: UUID) async throws -> PaotuiChatReply {
        try await controller.select(reply.card!, .init(action: .choose, value: value), conversationID: id)
    }
    func confirmation(_ request: PaotuiChatReply, _ id: UUID) async throws -> PaotuiChatReply {
        let quote = try await controller.select(request.card!, .init(action: .quote), conversationID: id)
        return try await choose(quote, quote.card!.options[0].id, id)
    }
}

@main struct LifecycleChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    @MainActor static func reject(_ operation: () async throws -> Void, _ label: String) async {
        do { try await operation(); preconditionFailure(label) } catch { checks += 1 }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cleared = try LifecycleScenario(root: root), clearedID = UUID(), otherID = UUID()
        let oldRequest = try await cleared.request(clearedID, goods: "清空前专属物品", inquiryOnly: true)
        let oldCard = try await cleared.confirmation(oldRequest, clearedID).card!
        let otherCard = try await cleared.confirmation(cleared.request(otherID), otherID).card!
        cleared.controller.clearPreparation(conversationID: clearedID)
        expect(!cleared.controller.isCurrent(oldCard), "Clear revokes the old confirmation even though conversation identity is unchanged")
        expect(cleared.controller.isCurrent(otherCard), "Clear revokes only the selected conversation's preparation")
        await reject({ _ = try await cleared.controller.select(oldCard, .init(action: .confirm), conversationID: clearedID) }, "Cleared card submitted")
        let blank = try await cleared.respond(clearedID, plan: [:])
        expect(blank.card?.kind == "mode" && blank.card?.goods == "" && blank.card?.recipientAddress == "", "A cleared conversation starts with no previous goods or selected address")
        expect(blank.card?.inquiryOnly == false && cleared.planner.prompts.last?.contains("清空前专属物品") == false, "Cleared business restrictions and details do not reenter model context")
        _ = try await cleared.controller.select(otherCard, .init(action: .confirm), conversationID: otherID)
        let createdBytes = try Data(contentsOf: cleared.receiptURL), orderID = cleared.store.lastOrderID
        cleared.controller.clearPreparation(conversationID: otherID)
        let retainedCreatedBytes = try Data(contentsOf: cleared.receiptURL)
        expect(orderID != nil && cleared.store.lastOrderID == orderID && retainedCreatedBytes == createdBytes,
            "Clearing preparation never erases a previously created order receipt")

        let ai = try LifecycleScenario(root: root), aiID = UUID(), aiGate = LifecycleGate()
        ai.planner.nextGate = aiGate
        let aiWork = Task { try await ai.request(aiID, goods: "延迟模型旧需求") }
        await aiGate.waitUntilEntered()
        ai.controller.clearPreparation(conversationID: aiID)
        let afterAI = try await ai.respond(aiID, plan: [:])
        aiGate.resume()
        await reject({ _ = try await aiWork.value }, "Late model interpretation recreated cleared preparation")
        expect(afterAI.card?.kind == "mode" && afterAI.card?.goods == "", "A late model response cannot contaminate the next cleared-chat request")
        expect(ai.controller.isCurrent(afterAI.card!), "Clear and immediate recreation leave the new canonical session current after a late model reply")

        let supersededAI = try LifecycleScenario(root: root), supersededID = UUID(), supersededGate = LifecycleGate()
        supersededAI.planner.nextGate = supersededGate
        let olderInterpretation = Task { try await supersededAI.request(supersededID, goods: "较早模型需求") }
        await supersededGate.waitUntilEntered()
        let replacementInterpretation = try await supersededAI.request(supersededID, goods: "后来明确的新需求")
        supersededGate.resume()
        await reject({ _ = try await olderInterpretation.value }, "A late model result used the shared session's newer ticket")
        expect(supersededAI.controller.isCurrent(replacementInterpretation.card!) && replacementInterpretation.card?.goods == "后来明确的新需求",
            "The exact pre-model ticket prevents an older result from changing the same live session")

        for endpoint in ["get_address_list", "search_poi", "delivery_preview", "submit_order"] {
            let scenario = try LifecycleScenario(root: root), id = UUID(), gate = LifecycleGate()
            let work: Task<PaotuiChatReply, Error>
            if endpoint == "get_address_list" || endpoint == "search_poi" {
                scenario.backend.gates[endpoint] = gate
                work = Task { try await scenario.request(id, merchant: endpoint == "search_poi") }
            } else {
                let request = try await scenario.request(id)
                if endpoint == "delivery_preview" {
                    scenario.backend.gates[endpoint] = gate
                    work = Task { try await scenario.controller.select(request.card!, .init(action: .quote), conversationID: id) }
                } else {
                    let confirm = try await scenario.confirmation(request, id)
                    scenario.backend.gates[endpoint] = gate
                    work = Task { try await scenario.controller.select(confirm.card!, .init(action: .confirm), conversationID: id) }
                }
            }
            await gate.waitUntilEntered()
            if endpoint == "submit_order" { work.cancel() }
            scenario.controller.clearPreparation(conversationID: id); gate.resume()
            await reject({ _ = try await work.value }, "Late \(endpoint) response recreated a cleared conversation")
            let fresh = try await scenario.respond(id, plan: [:])
            expect(fresh.card?.kind == "mode" && fresh.card?.goods == "", "Clear leaves no preparation after \(endpoint)")
            if endpoint == "submit_order" {
                let restored = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: scenario.receiptURL, clientFactory: scenario.backend.client)
                expect(restored.lastOrderID != nil && scenario.backend.fixture.submissions.count == 1,
                    "A dispatched order completes its durable receipt even when clear cancels its chat task")
            } else {
                expect(scenario.backend.fixture.submissions.isEmpty, "Cleared read operation never creates an order")
            }
        }

        for endpoint in ["get_address_list", "search_poi", "delivery_preview"] {
            let scenario = try LifecycleScenario(root: root), id = UUID()
            let failure: PaotuiChatReply
            if endpoint == "delivery_preview" {
                let request = try await scenario.request(id)
                scenario.backend.failingEndpoint = endpoint
                failure = try await scenario.controller.select(request.card!, .init(action: .quote), conversationID: id)
            } else {
                scenario.backend.failingEndpoint = endpoint
                failure = try await scenario.request(id, merchant: endpoint == "search_poi")
            }
            expect(failure.card?.kind == "info" && scenario.controller.isCurrent(failure.card!), "Failed \(endpoint) returns an active recovery card")
            expect(failure.card?.goods == "本次水一瓶" && failure.card?.options.map(\.id) == ["retry_read", "edit_preparation"],
                "Read recovery retains the demand and offers retry/edit choices")
            expect(failure.card?.canCreateOrder == false && scenario.backend.fixture.submissions.isEmpty,
                "Read recovery does not carry order confirmation authority")
            let modelCalls = scenario.planner.calls
            scenario.backend.failingEndpoint = nil
            let retry = try await scenario.choose(failure, "retry_read", id)
            let expectedKind = endpoint == "search_poi" ? "places" : endpoint == "delivery_preview" ? "quotes" : "request"
            expect(retry.card?.kind == expectedKind && retry.card?.goods == "本次水一瓶", "Retry resumes the exact failed read with its preserved demand")
            expect(scenario.planner.calls == modelCalls && scenario.backend.fixture.submissions.isEmpty,
                "Retrying a read uses no new model interpretation or submission")
        }

        let edit = try LifecycleScenario(root: root), editID = UUID()
        edit.backend.failingEndpoint = "get_address_list"
        let failedEdit = try await edit.request(editID)
        let editPrompt = try await edit.choose(failedEdit, "edit_preparation", editID)
        expect(editPrompt.card?.goods == "本次水一瓶" && editPrompt.card?.options.isEmpty == true, "Recovery edit keeps the draft while asking what to change")
        edit.backend.failingEndpoint = nil
        let edited = try await edit.respond(editID, plan: ["goods": "改成两瓶水"])
        expect(edited.card?.kind == "request" && edited.card?.goods == "改成两瓶水", "Recovery edit accepts a correction without restarting all fields")
        let beforeStandardEdit = try await edit.confirmation(edited, editID)
        let standardEdit = try await edit.controller.select(beforeStandardEdit.card!, .init(action: .edit), conversationID: editID)
        expect(standardEdit.card?.kind == "info" && edit.controller.isCurrent(standardEdit.card!), "Normal edit publishes its new request scope before validating the retained draft")
        expect(!edit.controller.isCurrent(beforeStandardEdit.card!), "Normal edit revokes the former quote confirmation")
        let afterStandardEdit = try await edit.respond(editID, plan: ["remark": "放门口"])
        expect(afterStandardEdit.card?.kind == "request" && afterStandardEdit.card?.goods == "改成两瓶水" && afterStandardEdit.card?.remark == "放门口",
            "Normal edit preserves goods and addresses while applying only the latest correction")

        let unknown = try LifecycleScenario(root: root), unknownID = UUID()
        let unknownCard = try await unknown.confirmation(unknown.request(unknownID), unknownID)
        unknown.backend.fixture.failSubmit = true
        let unknownReply = try await unknown.controller.select(unknownCard.card!, .init(action: .confirm), conversationID: unknownID)
        expect(unknown.store.hasUnresolvedSubmission && unknownReply.card?.options.contains(where: { $0.id == "retry_read" }) != true,
            "An uncertain submission never enters the read-retry path")
        let unknownBytes = try Data(contentsOf: unknown.receiptURL)
        unknown.controller.clearPreparation(conversationID: unknownID)
        let retainedUnknownBytes = try Data(contentsOf: unknown.receiptURL)
        expect(unknown.store.hasUnresolvedSubmission && retainedUnknownBytes == unknownBytes,
            "Clearing an uncertain order's preparation preserves its durable global barrier")
        expect(unknown.backend.fixture.submissions.count == 1, "No clear, correction or recovery action replays a submission")
        print("PASS: \(checks) preparation clear lifecycle, late model/read/submit ownership, actionable read recovery and order receipt preservation; offline fixtures only")
    }
}
