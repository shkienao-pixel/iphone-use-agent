import Foundation

/// The only adapter that can read the live preparation. It exports inert
/// values, never the session's authority-bearing types.
extension PaotuiSessionSummary {
    @MainActor init(session: PaotuiSession, locations: [PaotuiAddress], unresolved: Bool,
                    canCreateOrder: (PaotuiQuote) -> Bool) {
        guard let conversationID = session.origin.conversationID else {
            preconditionFailure("A chat summary requires a conversation session")
        }
        self.conversationID = conversationID
        switch session.phase {
        case .collecting: phase = .collecting
        case .clarifying: phase = .clarifying
        case .readyForReview: phase = .readyForReview
        case .reading: phase = .reading
        case .quoted: phase = .quoted
        case .awaitingConfirmation: phase = .awaitingConfirmation
        case .submitting: phase = .submitting
        case .outcome: phase = .outcome
        case .readFailed: phase = .readFailed
        case .closed: phase = .closed
        }
        let value = session.draft
        draft = Draft(service: value.service?.rawValue, goods: PaotuiAddress.redactingPhones(value.goods), nearby: value.nearby,
                      remark: PaotuiAddress.redactingPhones(value.remark), weight: value.weight, category: value.category?.title)
        sender = locations.first { $0.id == value.senderID }.map(Place.init)
        recipient = locations.first { $0.id == value.recipientID }.map(Place.init)
        places = session.places.map(Place.init)
        quotes = session.quotes.map { Quote($0, canCreateOrder: canCreateOrder($0)) }
        inquiryOnly = session.preparation.inquiryOnly; hasUnresolvedSubmission = unresolved
        missingFields = value.missingFields.map(\.rawValue)
    }
}

extension PaotuiSessionSummary.Place {
    init(_ value: PaotuiAddress) {
        id = value.id; title = PaotuiAddress.redactingPhones(value.title)
        fullAddress = PaotuiAddress.redactingPhones(value.fullAddress)
        contact = PaotuiAddress.redactingPhones([value.contact, value.maskedPhone]
            .filter { !$0.isEmpty }.joined(separator: " · "))
    }
}
extension PaotuiSessionSummary.Quote {
    init(_ value: PaotuiQuote, canCreateOrder: Bool) {
        id = value.id; senderTitle = PaotuiAddress.redactingPhones(value.senderTitle)
        recipientTitle = PaotuiAddress.redactingPhones(value.recipientTitle)
        senderContact = value.senderContact.map(PaotuiAddress.redactingPhones)
        recipientContact = value.recipientContact.map(PaotuiAddress.redactingPhones)
        serviceTitle = PaotuiAddress.redactingPhones(value.serviceTitle); isSend = value.draft.service == .send
        fee = value.fee; estimate = PaotuiAddress.redactingPhones(value.estimate)
        distance = PaotuiAddress.redactingPhones(value.distance)
        currency = value.deliveryAmount?.currency.rawValue
        deliveryFeeMinorUnits = value.deliveryAmount?.minorUnits
        feeText = value.deliveryAmount.map { $0.displayText + " 元" }
        goodsPaymentNote = PaotuiAddress.redactingPhones(value.goodsPaymentNote); validUntil = value.validUntil
        self.canCreateOrder = canCreateOrder
    }
}
