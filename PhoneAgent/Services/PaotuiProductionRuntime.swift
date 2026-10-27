import Foundation
import UIKit

/// Platform composition is the only place that chooses the real secure vault
/// and URL launcher. The production core has no dependency on either singleton.
@MainActor enum PaotuiProductionRuntime {
    static func makeStore() -> MeituanPaotuiStore {
        let vault = PaotuiCredentialVault(
            read: { ConnectionCredentialStore.read("meituan-paotui-token") },
            save: { try ConnectionCredentialStore.save($0, account: "meituan-paotui-token") })
        let clock = PaotuiClock.system
        return MeituanPaotuiStore(connection: PaotuiConnection(vault: vault, clock: clock),
            preparationRepository: PaotuiPreparationRepository(url: URL.applicationSupportDirectory.appendingPathComponent("PhoneAgent/paotui-preparations.json")),
            openURL: openURL)
    }

    static func openURL(_ url: URL) async -> Bool { await UIApplication.shared.open(url) }
}

@MainActor extension MeituanPaotuiStore {
    static let shared = PaotuiProductionRuntime.makeStore()
}

@MainActor extension MeituanPaotuiConversation {
    static let shared = MeituanPaotuiConversation(store: .shared, openURL: PaotuiProductionRuntime.openURL)
}

@MainActor extension PaotuiModule {
    static let shared = PaotuiModule(store: .shared, conversation: .shared)
}
