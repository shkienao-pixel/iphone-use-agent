import Foundation

/// Explicit in-memory vault shared across reconstructed fixture stores, just as
/// secure storage survives a process instance. These are dependency values, not
/// substitute production/platform types.
@MainActor enum PaotuiFixtureRuntime {
    private static var credential = ""

    static func connection(clock: PaotuiClock? = nil) -> PaotuiConnection {
        let vault = PaotuiCredentialVault(read: { credential }, save: { credential = $0 })
        let authorization = PaotuiAuthorizationGateway(
            start: { fatalError("Offline fixture attempted authorization") },
            finish: { _ in fatalError("Offline fixture attempted authorization") })
        return PaotuiConnection(vault: vault, clock: clock, authorization: authorization)
    }

    /// Model the actual native selection and consumption boundary; no fixture
    /// may grant a workbench or task origin a submission exemption.
    static func confirmNativeQuote(_ quote: PaotuiQuote, in store: MeituanPaotuiStore,
                                   request: PaotuiSession.Ticket) throws {
        guard let id = request.origin.conversationID else { throw PaotuiSession.SessionError.queryOnly }
        let session = store.session(for: id)
        try session.validate(request)
        _ = try session.chooseQuote(quote.id, at: store.currentTime)
        var card = PaotuiChatCard(conversationID: id, kind: "confirm", title: "Fixture native confirmation")
        card.quoteID = quote.id; card.canCreateOrder = true
        _ = try session.consumeCard(session.offer(card))
        if let amount = quote.deliveryAmount, amount.minorUnits > 10_000 {
            try session.requireHighFeeAcknowledgement(quoteID: quote.id)
            _ = try session.consumeCard(session.offer(card))
        }
    }
}
