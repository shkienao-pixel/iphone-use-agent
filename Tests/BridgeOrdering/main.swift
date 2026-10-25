import Foundation

@main struct BridgeOrderingChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func rejects(_ label: String, operation: () async throws -> Void) async {
            do { try await operation(); expect(false, label) } catch { expect(true, label) }
        }
        func gate(_ id: UUID) async throws {
            for _ in 0..<2000 {
                if BridgeOrderingProbe.pending[id] != nil { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw AgentError.message("Offline ordering response did not reach its gate")
        }
        func status(_ message: String, service: String = "feishu", connected: Bool = true, state: String = "connected", installed: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["service": service, "installed": installed, "connected": connected, "state": state, "message": message])
        }
        let bridge = ExternalConnectionsCoordinator.shared
        func configure(_ name: String) throws {
            precondition(BridgeOrderingProbe.pending.isEmpty && BridgeOrderingProbe.plans.isEmpty)
            try bridge.saveBridge(endpoint: "https://ordering-" + name + ".invalid", token: "offline-only-" + name)
        }
        func disconnectTask() -> Task<Bool, Never> {
            Task { do { try await bridge.disconnect(.feishu); return true } catch { return false } }
        }

        // All six arrival orders keep the newest read, not the last delivery.
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            try configure("reads-" + order.map(String.init).joined())
            let identity = bridge.authorizationContext
            var ids: [UUID] = [], tasks: [Task<OfficeConnectionStatus?, Never>] = []
            for index in 0..<3 {
                let id = BridgeOrderingProbe.plan(try status("read-\(index)"))
                ids.append(id); tasks.append(Task { try? await bridge.verifiedStatus(.feishu) })
                try await gate(id)
            }
            for index in order { BridgeOrderingProbe.resume(ids[index]); _ = await tasks[index].value }
            let first = await tasks[0].value, middle = await tasks[1].value, latest = await tasks[2].value
            expect(first == nil && middle == nil, "Superseded reads do not escape to callers: \(order)")
            expect(latest?.message == "read-2" && bridge.statuses["feishu"]?.message == "read-2", "Newest read owns the cache in arrival order \(order)")
            expect(bridge.authorizationContext == identity, "Read ordering does not depend on re-pairing: \(order)")
        }

        try configure("old-refresh-error")
        let staleRefreshID = BridgeOrderingProbe.plan()
        let staleRefresh = Task { await bridge.refresh(.feishu) }
        try await gate(staleRefreshID); _ = try await bridge.verifiedStatus(.feishu)
        BridgeOrderingProbe.resume(staleRefreshID, failure: "older refresh failure"); await staleRefresh.value
        expect(bridge.statuses["feishu"]?.connected == true && bridge.bridgeAvailable, "Old refresh failure preserves a newer successful check")

        try configure("disconnect-read")
        let oldReadID = BridgeOrderingProbe.plan()
        let oldRead = Task { try? await bridge.verifiedStatus(.feishu) }
        try await gate(oldReadID); try await bridge.disconnect(.feishu)
        BridgeOrderingProbe.resume(oldReadID); let oldReadResult = await oldRead.value
        expect(oldReadResult == nil, "Read begun before disconnect cannot return an obsolete connected result")
        expect(bridge.statuses["feishu"]?.connected == false && bridge.statusLabel(.feishu) == "已断开", "Late pre-disconnect read cannot reconnect the account")

        try configure("old-health")
        let oldHealthID = BridgeOrderingProbe.plan()
        let oldHealth = Task { await bridge.checkBridge() }
        try await gate(oldHealthID); await bridge.checkBridge()
        BridgeOrderingProbe.resume(oldHealthID, failure: "older health failure"); await oldHealth.value
        expect(bridge.bridgeAvailable && bridge.bridgeMessage == "连接服务已就绪", "New health success owns availability over older health failure")

        try configure("health-versus-status")
        let oldHealthVsStatusID = BridgeOrderingProbe.plan()
        let oldHealthVsStatus = Task { await bridge.checkBridge() }
        try await gate(oldHealthVsStatusID); _ = try await bridge.verifiedStatus(.feishu)
        BridgeOrderingProbe.resume(oldHealthVsStatusID, failure: "older health failure"); await oldHealthVsStatus.value
        expect(bridge.bridgeAvailable && bridge.statuses["feishu"]?.connected == true, "New account evidence also supersedes an older health error")

        try configure("status-versus-health")
        let oldStatusVsHealthID = BridgeOrderingProbe.plan()
        let oldStatusVsHealth = Task { try? await bridge.verifiedStatus(.feishu) }
        try await gate(oldStatusVsHealthID); await bridge.checkBridge()
        BridgeOrderingProbe.resume(oldStatusVsHealthID, failure: "older account failure"); _ = await oldStatusVsHealth.value
        expect(bridge.bridgeAvailable && bridge.bridgeMessage == "连接服务已就绪", "Old account failure cannot erase newer service health")

        try configure("negative-health-boundary")
        let delayedStatusID = BridgeOrderingProbe.plan()
        let delayedStatus = Task { try? await bridge.verifiedStatus(.feishu) }
        try await gate(delayedStatusID)
        let negativeHealthID = BridgeOrderingProbe.plan()
        let negativeHealth = Task { await bridge.checkBridge() }
        try await gate(negativeHealthID); BridgeOrderingProbe.resume(negativeHealthID, failure: "current health failure"); await negativeHealth.value
        BridgeOrderingProbe.resume(delayedStatusID); let invalidatedStatus = await delayedStatus.value
        expect(invalidatedStatus == nil && bridge.statuses["feishu"] == nil && !bridge.bridgeAvailable, "Current health failure invalidates older in-flight readiness proofs")
        await bridge.checkBridge()
        expect(bridge.bridgeAvailable && bridge.statuses["feishu"] == nil, "Health recovery does not invent account verification")
        _ = try await bridge.verifiedStatus(.feishu)
        expect(bridge.statuses["feishu"]?.connected == true, "Fresh independent account verification restores readiness")

        try configure("parallel-services")
        let firstID = BridgeOrderingProbe.plan()
        let first = Task { try? await bridge.verifiedStatus(.feishu) }
        try await gate(firstID)
        let secondID = BridgeOrderingProbe.plan()
        let second = Task { try? await bridge.verifiedStatus(.dingtalk) }
        try await gate(secondID); BridgeOrderingProbe.resume(firstID); let firstResult = await first.value
        expect(firstResult?.connected == true && bridge.bridgeAvailable, "A valid independent service can establish availability while another check waits")
        BridgeOrderingProbe.resume(secondID, failure: "newer current connection failure"); _ = await second.value
        expect(!bridge.bridgeAvailable && bridge.statuses["feishu"]?.connected != true, "A newer current connection failure removes older active readiness")

        // A mutation blocks competing operations for that service until settled.
        try configure("pending-disconnect"); _ = try await bridge.verifiedStatus(.feishu)
        let beforeDisconnect = BridgeOrderingProbe.calls.count
        let disconnectID = BridgeOrderingProbe.plan()
        let disconnect = disconnectTask(); try await gate(disconnectID)
        expect(bridge.statuses["feishu"]?.connected != true && bridge.statusLabel(.feishu) == "断开中", "Pending disconnect clears the direct readiness flag and exposes progress")
        let whilePending = BridgeOrderingProbe.calls.count
        await rejects("Status checks cannot run during same-service disconnect") { _ = try await bridge.verifiedStatus(.feishu) }
        await rejects("Duplicate disconnect cannot be submitted") { try await bridge.disconnect(.feishu) }
        for install in [false, true] {
            await rejects("Authorization/install cannot overlap disconnect") { _ = try await bridge.start(.feishu, install: install) }
        }
        await bridge.refresh(.feishu)
        expect(BridgeOrderingProbe.calls.count == whilePending, "Rejected competing operations start no transport and no duplicate POST")
        _ = try await bridge.verifiedStatus(.dingtalk)
        expect(bridge.statuses["dingtalk"]?.connected == true && bridge.statusLabel(.feishu) == "断开中", "Other service checks remain usable during disconnect")
        BridgeOrderingProbe.resume(disconnectID); let disconnected = await disconnect.value
        expect(disconnected && bridge.statusLabel(.feishu) == "已断开", "Acknowledged disconnect publishes its verified inactive result")
        expect(BridgeOrderingProbe.calls.dropFirst(beforeDisconnect).filter { $0.path.hasSuffix("/disconnect") }.count == 1, "Exactly one disconnect POST is submitted")

        for cancelled in [false, true] {
            try configure(cancelled ? "cancelled-mutation" : "failed-mutation"); _ = try await bridge.verifiedStatus(.feishu)
            let id = BridgeOrderingProbe.plan(), start = BridgeOrderingProbe.calls.count
            let task = disconnectTask(); try await gate(id)
            if cancelled { task.cancel(); BridgeOrderingProbe.resume(id) }
            else { BridgeOrderingProbe.resume(id, failure: "disconnect response lost") }
            let success = await task.value
            expect(!success, "Interrupted disconnect is not reported as successful: cancel=\(cancelled)")
            expect(bridge.statusLabel(.feishu) == "待检测" && bridge.statuses["feishu"]?.connected != true, "Interrupted disconnect remains unknown and never ready: cancel=\(cancelled)")
            await bridge.checkBridge()
            expect(bridge.statusLabel(.feishu) == "待检测", "Health-only evidence cannot resolve an unknown account mutation")
            _ = try await bridge.verifiedStatus(.feishu)
            expect(bridge.statusLabel(.feishu) == "已连接", "Independent current status can resolve unknown state without resending the mutation")
            expect(BridgeOrderingProbe.calls.dropFirst(start).filter { $0.path.hasSuffix("/disconnect") }.count == 1, "Failure/cancellation never automatically resends disconnect")
        }

        for reply in [try status("still connected"), try status("unknown", connected: false, state: "error"), try status("wrong service", service: "dingtalk", connected: false, state: "disconnected")] {
            try configure("invalid-disconnect"); _ = try await bridge.verifiedStatus(.feishu)
            _ = BridgeOrderingProbe.plan(reply, gated: false)
            await rejects("Unverified disconnect response cannot become a success receipt") { try await bridge.disconnect(.feishu) }
            expect(bridge.statusLabel(.feishu) == "待检测" && bridge.statuses["feishu"]?.connected != true, "Invalid disconnect acknowledgement never leaves the account ready")
        }
        try configure("inactive-preservation")
        _ = BridgeOrderingProbe.plan(try status("prior inactive", connected: false, state: "login"), gated: false)
        _ = try await bridge.verifiedStatus(.feishu)
        _ = BridgeOrderingProbe.plan(try status("wrong service", service: "dingtalk", connected: false, state: "disconnected"), gated: false)
        await rejects("Wrong-service mutation reply is rejected") { try await bridge.disconnect(.feishu) }
        expect(bridge.statuses["feishu"]?.message == "prior inactive" && bridge.statusLabel(.feishu) == "待检测", "Prior matching inactive observation is retained without becoming a resolved mutation")

        for oldFailure in [false, true] {
            try configure("old-owner")
            let oldID = BridgeOrderingProbe.plan(), oldTask = disconnectTask()
            try await gate(oldID)
            try bridge.saveBridge(endpoint: "https://new-owner.invalid", token: "offline-only-new-owner")
            let newID = BridgeOrderingProbe.plan(), newTask = disconnectTask()
            try await gate(newID)
            BridgeOrderingProbe.resume(oldID, failure: oldFailure ? "old pairing failure" : nil)
            let oldSuccess = await oldTask.value
            expect(!oldSuccess && bridge.statusLabel(.feishu) == "断开中", "Old mutation cleanup cannot release the replacement pairing's owner")
            let count = BridgeOrderingProbe.calls.count
            await rejects("Replacement mutation remains exclusive after old completion") { _ = try await bridge.verifiedStatus(.feishu) }
            expect(BridgeOrderingProbe.calls.count == count, "Old completion cannot unlock competing transport against the new pairing")
            BridgeOrderingProbe.resume(newID); let newSuccess = await newTask.value
            expect(newSuccess && bridge.statusLabel(.feishu) == "已断开", "Replacement pairing can finish its own mutation normally")
        }

        try configure("pending-start")
        let startID = BridgeOrderingProbe.plan()
        let starting = Task { try? await bridge.start(.feishu, install: false) }
        try await gate(startID)
        let startCalls = BridgeOrderingProbe.calls.count
        expect(bridge.statusLabel(.feishu) == "连接更新中" && bridge.statuses["feishu"]?.connected != true, "Authorization start has its own visible mutation ownership")
        await rejects("Read does not overlap a same-service authorization start") { _ = try await bridge.verifiedStatus(.feishu) }
        await rejects("Disconnect does not overtake a pending authorization start") { try await bridge.disconnect(.feishu) }
        await rejects("Duplicate authorization start is not submitted") { _ = try await bridge.start(.feishu, install: false) }
        expect(BridgeOrderingProbe.calls.count == startCalls, "Competing authorization operations enter no transport")
        BridgeOrderingProbe.resume(startID); let startedJob = await starting.value
        expect(startedJob?.id == BridgeOrderingProbe.jobID, "Uninterrupted authorization start still returns its real job")
        _ = try await bridge.verifiedStatus(.feishu)
        expect(bridge.statusLabel(.feishu) == "已连接", "Normal status checks resume after authorization start settles")

        for malformed in [try status("contradictory", connected: false, state: "connected"), try status("missing CLI", installed: false)] {
            try configure("contradictory-status")
            _ = BridgeOrderingProbe.plan(malformed, gated: false)
            await rejects("Contradictory connected flags are not accepted as account evidence") { _ = try await bridge.verifiedStatus(.feishu) }
            expect(bridge.statuses["feishu"]?.connected != true && bridge.statusLabel(.feishu) != "已连接", "Contradictory reply cannot produce a connected readiness indicator")
        }

        expect(BridgeOrderingProbe.pending.isEmpty && BridgeOrderingProbe.plans.isEmpty, "Every controlled response has been delivered; no fixture is silently abandoned")
        let report: [String: Any] = ["checks": checks, "failures": failures,
            "scope": "Unchanged extracted coordinator, independent frozen HTTP response gates and in-memory stores; no network/accounts/iPhone acceptance."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
