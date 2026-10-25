import Foundation

@main struct BridgeIdentityChecks {
    @MainActor static func main() async throws {
        var failures: [String] = [], checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func settle() async throws {
            for _ in 0..<2000 {
                if BridgeResponseProbe.pending != nil { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw AgentError.message("Offline bridge gate did not start")
        }
        let bridge = ExternalConnectionsCoordinator.shared
        func configure(_ suffix: String) throws {
            try bridge.saveBridge(endpoint: "https://" + suffix + ".invalid", token: "offline-only-" + suffix)
        }
        func rejects(_ operation: () throws -> Void, _ label: String) {
            do { try operation(); expect(false, label) } catch { expect(true, label) }
        }
        func statusPayload(service: String, connected: Bool = true, state: String = "connected") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["service": service, "installed": true, "connected": connected,
                "state": state, "message": "offline explicit fixture"])
        }

        // Old deliveries must have no effect on either side of a re-pairing.
        try configure("old-health"); BridgeResponseProbe.gate = true
        let health = Task { await bridge.checkBridge() }
        try await settle(); try configure("new-health"); BridgeResponseProbe.resume(); await health.value
        expect(!bridge.bridgeAvailable, "Old health response cannot mark a replacement bridge ready")
        expect(bridge.bridgeMessage.isEmpty, "Old health response cannot replace the new configuration message")

        try configure("old-status"); BridgeResponseProbe.gate = true
        let status = Task { try? await bridge.verifiedStatus(.feishu) }
        try await settle(); try configure("new-status"); BridgeResponseProbe.resume(); _ = await status.value
        expect(bridge.statuses["feishu"] == nil, "Old account status cannot repopulate a replacement bridge cache")
        expect(!bridge.bridgeAvailable, "Rejected old account status does not prove the new service is available")

        try configure("old-failure"); BridgeResponseProbe.gate = true
        let failedRefresh = Task { await bridge.refresh(.feishu) }
        try await settle(); try configure("new-failure"); _ = try await bridge.verifiedStatus(.feishu)
        BridgeResponseProbe.resume(failing: true); await failedRefresh.value
        expect(bridge.statuses["feishu"]?.message == "new-failure.invalid" && bridge.bridgeAvailable,
               "Old refresh failure cannot erase the replacement bridge's verified status")
        expect(bridge.bridgeMessage.isEmpty, "Old refresh failure cannot publish a stale error over a new success")

        try configure("old-health-failure"); BridgeResponseProbe.gate = true
        let failedHealth = Task { await bridge.checkBridge() }
        try await settle(); try configure("new-health-failure"); await bridge.checkBridge()
        BridgeResponseProbe.resume(failing: true); await failedHealth.value
        expect(bridge.bridgeAvailable && bridge.bridgeMessage == "连接服务已就绪", "Old health failure cannot erase new health evidence")

        try configure("old-disconnect"); BridgeResponseProbe.gate = true
        let disconnect = Task { try? await bridge.disconnect(.feishu) }
        try await settle(); try configure("new-disconnect"); _ = try await bridge.verifiedStatus(.feishu)
        BridgeResponseProbe.resume(); _ = await disconnect.value
        expect(bridge.statuses["feishu"]?.connected == true && bridge.statuses["feishu"]?.message == "new-disconnect.invalid",
               "Old disconnect result cannot overwrite a replacement bridge account")

        try configure("same-endpoint")
        let identity = bridge.authorizationContext
        try bridge.saveBridge(endpoint: "https://same-endpoint.invalid", token: "different-offline-pairing")
        expect(identity != bridge.authorizationContext, "Re-pairing the same endpoint changes authorization identity")
        expect(!bridge.authorizationContext.contains("different-offline-pairing"), "Authorization identity never embeds the pairing credential")

        try configure("return-to-a"); BridgeResponseProbe.gate = true
        let originalA = Task { try? await bridge.verifiedStatus(.feishu) }
        try await settle(); try configure("temporary-b"); try configure("return-to-a")
        BridgeResponseProbe.resume(); _ = await originalA.value
        expect(bridge.statuses["feishu"] == nil, "Returning to the same endpoint does not revive an earlier pairing's in-flight response")

        // An unchanged configuration must survive an actual new coordinator.
        try configure("restart")
        let persistedIdentity = bridge.authorizationContext
        let persistedDefaults = UserDefaults.standard.values
        UserDefaults.standard.values = persistedDefaults
        let restarted = ExternalConnectionsCoordinator.freshOfflineInstance()
        expect(restarted.authorizationContext == persistedIdentity, "Fresh coordinator reads the same persisted authorization identity")
        expect(restarted.endpointText == bridge.endpointText && restarted.paired, "Unchanged pairing remains configured after coordinator recreation")
        expect(restarted.statuses.isEmpty && !restarted.bridgeAvailable, "Recreation restores configuration without inventing live account verification")
        UserDefaults.standard.values.removeValue(forKey: "connections.bridge.pairingIdentity")
        expect(restarted.authorizationContext == restarted.endpointText, "Legacy endpoint-only pending authorizations remain compatible until re-pairing")
        try configure("restart")
        expect(restarted.authorizationContext != restarted.endpointText, "The first new pairing leaves legacy identity behind")

        // Invalid or failed saves must not partly replace a working pairing.
        _ = try await bridge.verifiedStatus(.feishu)
        let savedIdentity = bridge.authorizationContext, savedEndpoint = bridge.endpointText, savedRevision = bridge.revision
        let savedCredential = ConnectionCredentialStore.values
        for bad in ["", "   ", "bad\nvalue", String(repeating: "x", count: 4097)] {
            rejects({ try bridge.saveBridge(endpoint: "https://new-invalid.invalid", token: bad) }, "Invalid pairing credential is rejected before committing configuration")
            expect(bridge.authorizationContext == savedIdentity && bridge.endpointText == savedEndpoint && bridge.revision == savedRevision,
                   "Invalid pairing credential preserves the persisted identity and endpoint")
        }
        rejects({ try bridge.saveBridge(endpoint: "http://invalid.invalid", token: "offline-only") }, "Invalid endpoint is rejected before changing credentials")
        expect(ConnectionCredentialStore.values == savedCredential, "Rejected pairing attempts preserve the prior credential boundary")
        ConnectionCredentialStore.failNextSave = true
        rejects({ try bridge.saveBridge(endpoint: "https://failed-write.invalid", token: "offline-only-replacement") }, "Credential storage failure is surfaced")
        expect(bridge.authorizationContext == savedIdentity && bridge.endpointText == savedEndpoint && bridge.revision == savedRevision,
               "Credential storage failure preserves pairing configuration and generation")
        expect(bridge.statuses["feishu"]?.connected == true && bridge.bridgeAvailable, "Rejected save does not delete a working account cache")

        // Deliberately uncooperative transport ignores cancellation until resumed.
        try configure("cancelled-status"); BridgeResponseProbe.gate = true
        let cancelled = Task { () -> Bool in
            do { _ = try await bridge.verifiedStatus(.feishu); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        try await settle(); cancelled.cancel(); BridgeResponseProbe.resume()
        let statusCancelled = await cancelled.value
        expect(statusCancelled, "Cancelled account check reports cancellation")
        expect(bridge.statuses["feishu"] == nil, "Cancelled account check cannot publish a late connected status")

        try configure("cancelled-health"); BridgeResponseProbe.gate = true
        let cancelledHealth = Task { await bridge.checkBridge() }
        try await settle(); cancelledHealth.cancel(); BridgeResponseProbe.resume(); await cancelledHealth.value
        expect(!bridge.bridgeAvailable && bridge.bridgeMessage.isEmpty, "Cancelled health check cannot publish availability or a stale error")

        try configure("cancelled-before-start")
        let callsBeforeCancellation = BridgeResponseProbe.calls.count
        let cancelledBeforeStart = Task {
            await bridge.checkBridge()
            _ = try? await bridge.verifiedStatus(.feishu)
            try? await bridge.disconnect(.feishu)
            _ = try? await bridge.start(.feishu, install: false)
            _ = try? await bridge.poll(BridgeResponseProbe.jobID)
            await bridge.cancel(BridgeResponseProbe.jobID)
            await bridge.refresh(.feishu)
            await bridge.refreshAll()
        }
        cancelledBeforeStart.cancel(); await cancelledBeforeStart.value
        expect(BridgeResponseProbe.calls.count == callsBeforeCancellation, "Already cancelled coordinator operations never enter transport")

        // Authorization jobs returned by another pairing must not escape to callers.
        try configure("old-start"); BridgeResponseProbe.gate = true
        let start = Task { try? await bridge.start(.feishu, install: false) }
        try await settle(); try configure("new-start"); BridgeResponseProbe.resume()
        let staleStart = await start.value
        expect(staleStart == nil, "Changed pairing rejects an old authorization start response")

        try configure("old-poll"); BridgeResponseProbe.gate = true
        let poll = Task { try? await bridge.poll(BridgeResponseProbe.jobID) }
        try await settle(); try configure("new-poll"); BridgeResponseProbe.resume()
        let stalePoll = await poll.value
        expect(stalePoll == nil, "Changed pairing rejects an old job poll response")

        try configure("old-refresh-all"); BridgeResponseProbe.gate = true
        let batchCalls = BridgeResponseProbe.calls.count
        let batch = Task { await bridge.refreshAll() }
        try await settle(); try configure("new-refresh-all"); BridgeResponseProbe.resume(); await batch.value
        expect(BridgeResponseProbe.calls.count == batchCalls + 1, "Old refresh-all stops before issuing later requests against a replacement pairing")
        expect(bridge.statuses.isEmpty, "A cancelled configuration batch cannot populate the new cache")

        // Positive and negative current-server replies retain their old semantics.
        try configure("current")
        await bridge.checkBridge()
        expect(bridge.bridgeAvailable && bridge.bridgeMessage == "连接服务已就绪", "Current health response still makes the bridge available")
        let currentStatus = try await bridge.verifiedStatus(.feishu)
        expect(currentStatus.connected && bridge.statusLabel(.feishu) == "已连接", "Current verified account still appears connected")
        try await bridge.disconnect(.feishu)
        expect(bridge.statuses["feishu"]?.connected == false && bridge.statusLabel(.feishu) == "已断开", "Current disconnect still updates its own account")
        BridgeResponseProbe.nextPayload = try statusPayload(service: "feishu", connected: false, state: "login")
        _ = try await bridge.verifiedStatus(.feishu)
        expect(bridge.statusLabel(.feishu) == "待登录", "Current unauthenticated account never becomes a connected account")
        BridgeResponseProbe.nextPayload = try statusPayload(service: "dingtalk")
        do { _ = try await bridge.verifiedStatus(.feishu); expect(false, "Wrong-service status is rejected") }
        catch { expect(true, "Wrong-service status is rejected") }
        expect(bridge.statuses["feishu"]?.state == "login", "Rejected wrong-service status preserves the prior matching account")
        BridgeResponseProbe.nextPayload = try statusPayload(service: "dingtalk", connected: false, state: "disconnected")
        do { try await bridge.disconnect(.feishu); expect(false, "Wrong-service disconnect response is rejected") }
        catch { expect(true, "Wrong-service disconnect response is rejected") }
        expect(bridge.statuses["feishu"]?.state == "login", "Rejected wrong-service disconnect cannot replace a matching account")
        _ = try await bridge.verifiedStatus(.feishu)
        BridgeResponseProbe.gate = true
        let currentFailure = Task { await bridge.refresh(.feishu) }
        try await settle(); BridgeResponseProbe.resume(failing: true); await currentFailure.value
        expect(bridge.statuses["feishu"] == nil && !bridge.bridgeAvailable && !bridge.bridgeMessage.isEmpty,
               "A genuine current-service failure still clears its own stale connected status")
        await bridge.refreshAll()
        expect(ExternalAppService.allCases.filter(\.isCLI).allSatisfy { bridge.statuses[$0.rawValue]?.connected == true },
               "Unchanged refresh-all still verifies each CLI account")

        let report: [String: Any] = ["checks": checks, "failures": failures,
            "mode": "unchanged extracted coordinator; only in-memory defaults, fake credentials and gated local transport",
            "requestCount": BridgeResponseProbe.calls.count]
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: encoded, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
