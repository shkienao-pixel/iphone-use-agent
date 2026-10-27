import Foundation
import CryptoKit

@MainActor private final class ResponseGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func next() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
            observers.forEach { $0.resume() }
            observers = []
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume(_ value: Value) {
        precondition(continuation != nil)
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// This URLProtocol terminates every request in memory. The transport itself is
/// the production implementation, including URLSession and its delegate.
private final class OfflineHTTPProtocol: URLProtocol {
    static var body = Data()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @main private struct PaotuiConnectionChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        checks += 1
        precondition(value, label)
    }
    static func rejects(_ label: String, _ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure(label) }
        catch { checks += 1 }
    }
    static func session(_ time: Date, code: String = "fixture-code") -> MeituanPaotuiAuthorization.Session {
        .init(code: code, verifier: "fixture-verifier", link: URL(string: "https://dpurl.cn/fixture")!,
              expires: time.addingTimeInterval(600))
    }
    static func main() async throws {
        try await connectionChecks()
        try await productionPassportAndClientChecks()
        try await transportChecks()
        print("PASS: \(checks) actual-source connection, credential, clock, Passport and HTTP checks; offline only")
    }

    static func connectionChecks() async throws {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaotuiClock(now: { time })
        var stored = "", writes: [String] = [], rejectSave = false
        let vault = PaotuiCredentialVault(read: { stored }, save: { value in
            if rejectSave { throw CocoaError(.fileWriteUnknown) }
            stored = value; writes.append(value)
        })
        var startGate: ResponseGate<MeituanPaotuiAuthorization.Session>?
        var finishGate: ResponseGate<String?>?
        var finishValue: String?, finishCalls = 0
        let connection = PaotuiConnection(vault: vault, clock: clock, authorization: .init(
            start: {
                if let startGate { return try await startGate.next() }
                return session(time)
            }, finish: { _ in
                finishCalls += 1
                if let finishGate { return try await finishGate.next() }
                return finishValue
            }))
        var changes = 0
        connection.onChange = { changes += 1 }
        expect(!connection.configured && connection.authorizationLink == nil, "Empty vault is disconnected")
        for value in ["", "credential\n", String(repeating: "x", count: 8193), "凭据"] {
            await rejects("Invalid credential must not enter the vault") { try connection.installCredential(value) }
        }
        expect(writes.isEmpty && changes == 0, "Rejected credentials publish no mutation")
        let initial = connection.epoch
        try connection.installCredential("fixture-credential")
        expect(connection.configured && stored == "fixture-credential" && connection.epoch != initial, "Install saves before advancing authority")
        let fingerprint = SHA256.hash(data: Data(stored.utf8)).map { String(format: "%02x", $0) }.joined()
        expect(connection.credentialFingerprint == fingerprint, "Fingerprint describes credential version")
        let installed = connection.epoch
        try connection.installCredential("fixture-credential")
        expect(connection.epoch != installed, "Same-token reinstall still advances authority")
        let key = connection.credential, epoch = connection.epoch
        stored = "external-fixture"
        await rejects("External vault switch revokes captured credential") { try connection.checkCredential(key, epoch: epoch) }
        stored = key
        try connection.checkCredential(key, epoch: epoch)
        expect(connection.epoch == epoch, "Read-only checks do not mutate authority")

        let link = try await connection.startAuthorization()
        expect(link == connection.authorizationLink && connection.epoch == epoch, "Start returns the host URL without changing credential authority")
        let waiting = try await connection.finishAuthorization()
        expect(!waiting && connection.authorizationLink == link && stored == key, "Waiting grant leaves current credential and session intact")
        rejectSave = true; finishValue = "replacement-fixture"
        await rejects("Grant storage failure is surfaced") { _ = try await connection.finishAuthorization() }
        expect(connection.epoch == epoch && connection.authorizationLink == link && stored == key, "Failed grant save leaves coherent retryable state")
        rejectSave = false
        let finished = try await connection.finishAuthorization()
        expect(finished && stored == "replacement-fixture" && connection.authorizationLink == nil && connection.epoch != epoch, "Finished grant installs and clears session")

        startGate = ResponseGate()
        let canceledStart = Task { try await connection.startAuthorization() }
        await startGate!.started()
        let beforeCancel = connection.epoch
        connection.cancelAuthorization()
        startGate!.resume(session(time))
        await rejects("Canceled start cannot restore a link") { _ = try await canceledStart.value }
        expect(connection.authorizationLink == nil && connection.epoch != beforeCancel, "Cancel revokes connection epoch")

        startGate = ResponseGate()
        let taskCanceledStart = Task { try await connection.startAuthorization() }
        await startGate!.started()
        taskCanceledStart.cancel()
        startGate!.resume(session(time))
        await rejects("Task cancellation cannot publish a late start") { _ = try await taskCanceledStart.value }
        expect(connection.authorizationLink == nil, "Canceled task has no link")

        let oldGate = ResponseGate<MeituanPaotuiAuthorization.Session>()
        startGate = oldGate
        let oldStart = Task { try await connection.startAuthorization() }
        await oldGate.started()
        startGate = nil
        _ = try await connection.startAuthorization()
        oldGate.resume(session(time, code: "old-code"))
        await rejects("New authorization start supersedes older start") { _ = try await oldStart.value }
        expect(connection.authorizationLink != nil, "New session survives superseded start response")

        finishGate = ResponseGate()
        let disconnectedFinish = Task { try await connection.finishAuthorization() }
        await finishGate!.started()
        try connection.disconnect()
        finishGate!.resume("late-grant")
        await rejects("Disconnect cannot be undone by an in-flight grant") { _ = try await disconnectedFinish.value }
        expect(stored.isEmpty && connection.authorizationLink == nil, "Disconnect clears vault and auth session")

        finishGate = nil
        _ = try await connection.startAuthorization()
        finishGate = ResponseGate()
        let sameTokenFinish = Task { try await connection.finishAuthorization() }
        await finishGate!.started()
        try connection.installCredential("same-token-fixture")
        let newerEpoch = connection.epoch
        finishGate!.resume("late-different-grant")
        await rejects("Direct credential install revokes an in-flight finish") { _ = try await sameTokenFinish.value }
        expect(stored == "same-token-fixture" && connection.epoch == newerEpoch, "Late grant cannot overwrite installed credential")

        finishGate = nil
        _ = try await connection.startAuthorization()
        finishGate = ResponseGate()
        let canceledWaiting = Task { try await connection.finishAuthorization() }
        await finishGate!.started()
        connection.cancelAuthorization()
        finishGate!.resume(nil)
        await rejects("A canceled pending response cannot publish waiting state") { _ = try await canceledWaiting.value }

        finishGate = nil
        _ = try await connection.startAuthorization()
        time = time.addingTimeInterval(601)
        let beforeExpiredCalls = finishCalls
        await rejects("Expired session is rejected before the gateway") { _ = try await connection.finishAuthorization() }
        expect(finishCalls == beforeExpiredCalls, "Expired session makes no request")

        _ = try await connection.startAuthorization()
        finishGate = ResponseGate()
        let expiresDuringFinish = Task { try await connection.finishAuthorization() }
        await finishGate!.started()
        time = time.addingTimeInterval(601)
        finishGate!.resume("expired-late-grant")
        await rejects("Grant arriving after expiry cannot install") { _ = try await expiresDuringFinish.value }
        expect(stored == "same-token-fixture", "Late expired grant leaves vault unchanged")
        rejectSave = true
        let beforeFailedDisconnect = connection.epoch, beforeFailedLink = connection.authorizationLink
        await rejects("Disconnect storage failure is surfaced") { try connection.disconnect() }
        expect(connection.epoch == beforeFailedDisconnect && connection.authorizationLink == beforeFailedLink, "Failed disconnect publishes no authority change")
        expect(changes > 0, "Connection mutations notify the host")
    }

    static func productionPassportAndClientChecks() async throws {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaotuiClock(now: { time })
        var requests: [URLRequest] = [], redirected = false
        var payload: [String: Any] = ["authCode": "fixture-code", "shortLink": "https://dpurl.cn/fixture"]
        let authorization = MeituanPaotuiAuthorization(transport: { request in
            requests.append(request)
            return (try JSONSerialization.data(withJSONObject: ["code": 0, "data": payload]),
                    HTTPURLResponse(url: redirected ? URL(string: "https://wrong.invalid/")! : request.url!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: clock)
        let session = try await authorization.start()
        let request = requests[0]
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        expect(components.host == "passport.meituan.com" && components.path == "/api/account/userauth/code", "Actual Passport origin and path remain pinned")
        let challenge = SHA256.hash(data: Data(session.verifier.utf8)).map { String(format: "%02x", $0) }.joined()
        expect(query["client_id"] == MeituanPaotuiAuthorization.clientID && query["code_challenge"] == challenge && session.verifier.count == 64, "Actual Passport retains hex PKCE")
        expect(request.timeoutInterval == 25 && !request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "cli-version") == "1.0.5", "Passport request policies remain exact")
        expect(session.expires == time.addingTimeInterval(600), "Authorization expiry uses injected clock")
        payload = ["authStatus": 4, "authMode": 1, "accessToken": "fixture-grant"]
        let grant = try await authorization.finish(session)
        expect(grant == "fixture-grant", "Actual Passport finish uses injected transport")
        let finishParts = URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!
        let finishQuery = Dictionary(uniqueKeysWithValues: finishParts.queryItems!.map { ($0.name, $0.value!) })
        expect(finishQuery["auth_code"] == session.code && finishQuery["code_verifier"] == session.verifier, "Actual finish remains bound to same PKCE session")
        time = session.expires
        let count = requests.count
        await rejects("Injected clock enforces expiry without network") { _ = try await authorization.finish(session) }
        expect(requests.count == count, "Expired Passport session does not call transport")
        redirected = true
        await rejects("Actual Passport rejects changed response URL") { _ = try await authorization.start() }

        let success = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["code": 0, "data": ["accepted": true]]])
        let client = MeituanPaotuiClient(credential: "fixture-credential", transport: { request in
            (success, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { time })
        let clientRequest = try client.request(.preview, payload: ["fixture": true])
        let body = try JSONSerialization.jsonObject(with: clientRequest.httpBody!) as! [String: Any]
        expect(body["ajaxId"] as? String == "\(Int(time.timeIntervalSince1970 * 1000))_1532", "Client request timestamp uses injected time")
        expect(clientRequest.timeoutInterval == 35 && !clientRequest.httpShouldHandleCookies && clientRequest.value(forHTTPHeaderField: "mtcp-ak") == "fixture-credential", "Client request policy and credential header are preserved")
        var invalidOriginClient = client
        invalidOriginClient.transport = { _ in (success, HTTPURLResponse(url: URL(string: "https://wrong.invalid/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        let invalidOrigin = invalidOriginClient
        await rejects("Actual client rejects changed response origin") { _ = try await invalidOrigin.call(.preview) }

        let submitGate = ResponseGate<(Data, HTTPURLResponse)>()
        var submittedClient = client
        submittedClient.transport = { _ in try await submitGate.next() }
        let submitting = submittedClient
        let submittedTask = Task { try await submitting.call(.submit) }
        await submitGate.started()
        submittedTask.cancel()
        submitGate.resume((success, HTTPURLResponse(url: URL(string: MeituanPaotuiClient.base + "submit_order")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        let submittedResult = try await submittedTask.value
        expect(submittedResult["accepted"] as? Bool == true, "Canceled submit still delivers returned provider fact")

        let readGate = ResponseGate<(Data, HTTPURLResponse)>()
        var readingClient = client
        readingClient.transport = { _ in try await readGate.next() }
        let reading = readingClient
        let readTask = Task { try await reading.call(.addresses) }
        await readGate.started()
        readTask.cancel()
        readGate.resume((success, HTTPURLResponse(url: URL(string: MeituanPaotuiClient.base + "get_address_list")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        await rejects("Canceled read response does not publish") { _ = try await readTask.value }

        let address = PaotuiAddress(id: "fixture", name: "fixture", address: "fixture", houseNumber: "1", contact: "fixture", maskedPhone: "138****0000", latitude: 1, longitude: 1, cityID: 1, savedID: 1, lastUse: 0)
        let quote = try MeituanPaotuiClient.quote(data: ["deliveryFeeView": ["totalAmount": 8], "total": 7, "orderToken": "fixture-token", "distanceDesc": "1km"], draft: PaotuiDraft(), sender: address, recipient: address, request: [:], account: "fixture-fingerprint", service: nil, quotedAt: time)
        expect(quote.quotedAt == time, "Quote factory accepts explicit quote time")
    }

    static func transportChecks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineHTTPProtocol.self]
        var request = URLRequest(url: URL(string: "https://offline.invalid/fixture")!, timeoutInterval: 17)
        request.httpShouldHandleCookies = false
        OfflineHTTPProtocol.requests = []
        OfflineHTTPProtocol.body = Data("data: {\"id\":1,\"result\":{}}\n\ntrailing-body".utf8)
        let (bytes, response) = try await PaotuiHTTPTransport.load(request, configuration: configuration)
        expect(bytes == OfflineHTTPProtocol.body && response.url == request.url, "Neutral HTTP reads the entire body without MCP/SSE early termination")
        expect(OfflineHTTPProtocol.requests.count == 1 && OfflineHTTPProtocol.requests[0].timeoutInterval == 17, "Transport preserves caller timeout with no retry")
        expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies && configuration.urlCache == nil && configuration.urlCredentialStorage == nil, "Transport strips shared cookie, cache and credential stores")
        OfflineHTTPProtocol.body = Data(repeating: 65, count: PaotuiHTTPTransport.maximumResponseBytes + 1)
        await rejects("Production transport rejects oversized body") { _ = try await PaotuiHTTPTransport.load(request, configuration: configuration) }
    }
}
