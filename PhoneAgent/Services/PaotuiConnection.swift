import Foundation
import CryptoKit

/// Connection authority is independent from preparation and durable order facts.
/// The host opens the URL returned by startAuthorization().
@MainActor final class PaotuiConnection {
    private let vault: PaotuiCredentialVault
    private let clock: PaotuiClock
    private let authorization: PaotuiAuthorizationGateway
    private var authorizationSession: MeituanPaotuiAuthorization.Session?
    private var authorizationGeneration = UUID()

    var onChange: (() -> Void)?
    private(set) var epoch = UUID()
    var credential: String { vault.read() }
    var configured: Bool { !credential.isEmpty }
    var currentTime: Date { clock.now() }
    /// This hashes a credential version. It is not a stable provider account ID.
    var credentialFingerprint: String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var authorizationLink: URL? { authorizationSession?.link }

    init(vault: PaotuiCredentialVault, clock: PaotuiClock? = nil,
         authorization: PaotuiAuthorizationGateway? = nil) {
        self.vault = vault
        let clock = clock ?? .system
        self.clock = clock
        self.authorization = authorization ?? PaotuiAuthorizationGateway(
            authorization: MeituanPaotuiAuthorization(clock: clock))
    }

    func startAuthorization() async throws -> URL {
        // A newer start revokes a prior start/finish even when its transport
        // ignores cancellation and eventually returns a successful result.
        authorizationGeneration = UUID()
        authorizationSession = nil
        onChange?()
        let generation = authorizationGeneration, currentEpoch = epoch, key = credential
        let session = try await authorization.start()
        try checkAuthorization(generation, epoch: currentEpoch, credential: key)
        guard session.expires > clock.now() else { throw AgentError.message("授权链接已过期，请重新连接") }
        authorizationSession = session
        onChange?()
        return session.link
    }

    /// false means Passport is still waiting; true means the new credential was
    /// durably installed. There is no network retry or URL-opening side effect.
    func finishAuthorization() async throws -> Bool {
        guard let session = authorizationSession else { throw AgentError.message("请先连接美团跑腿") }
        guard session.expires > clock.now() else { throw AgentError.message("授权链接已过期，请重新连接") }
        let generation = authorizationGeneration, currentEpoch = epoch, key = credential
        let value = try await authorization.finish(session)
        try checkAuthorization(generation, epoch: currentEpoch, credential: key)
        guard session.expires > clock.now() else { throw AgentError.message("授权链接已过期，请重新连接") }
        guard let value else { return false }
        try installCredential(value)
        return true
    }

    func cancelAuthorization() {
        revokeAuthorization()
        epoch = UUID()
        onChange?()
    }

    func installCredential(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AgentError.message("跑腿授权格式无效")
        }
        // A failed save leaves both the current authority and pending session
        // intact, allowing the host to report a storage failure accurately.
        try vault.save(value)
        epoch = UUID()
        revokeAuthorization()
        onChange?()
    }

    func disconnect() throws {
        try vault.save("")
        epoch = UUID()
        revokeAuthorization()
        onChange?()
    }

    func checkCredential(_ value: String, epoch expected: UUID) throws {
        try Task.checkCancellation()
        guard value == credential, expected == epoch else {
            throw AgentError.message("跑腿连接已改变，请重新查询")
        }
    }

    private func checkAuthorization(_ generation: UUID, epoch expected: UUID, credential value: String) throws {
        try Task.checkCancellation()
        guard generation == authorizationGeneration, expected == epoch, value == credential else {
            throw CancellationError()
        }
    }

    private func revokeAuthorization() {
        authorizationGeneration = UUID()
        authorizationSession = nil
    }
}
