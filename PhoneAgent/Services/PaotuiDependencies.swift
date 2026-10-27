import Foundation

/// Time is supplied by the process composition so business state can be tested
/// without changing the device clock.
@MainActor struct PaotuiClock {
    let now: () -> Date

    init(now: @escaping () -> Date) { self.now = now }

    static let system = PaotuiClock(now: Date.init)
}

/// The connection owns credential policy; the host owns secure storage.
@MainActor struct PaotuiCredentialVault {
    let read: () -> String
    let save: (String) throws -> Void

    init(read: @escaping () -> String, save: @escaping (String) throws -> Void) {
        self.read = read
        self.save = save
    }
}

/// A narrow authorization boundary using the production PKCE session type.
@MainActor struct PaotuiAuthorizationGateway {
    let start: () async throws -> MeituanPaotuiAuthorization.Session
    let finish: (MeituanPaotuiAuthorization.Session) async throws -> String?

    init(start: @escaping () async throws -> MeituanPaotuiAuthorization.Session,
         finish: @escaping (MeituanPaotuiAuthorization.Session) async throws -> String?) {
        self.start = start
        self.finish = finish
    }

    init(authorization: MeituanPaotuiAuthorization) {
        self.init(start: { try await authorization.start() },
                  finish: { try await authorization.finish($0) })
    }
}
