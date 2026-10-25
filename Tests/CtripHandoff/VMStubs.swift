import Foundation
struct HandoffTestLog { var title:String; var detail:String }
struct HandoffTestRecord { var id:UUID; var goal:String; var updatedAt:Date; var logs:[HandoffTestLog] }
struct HandoffTestQueueItem { var id:UUID; var record:HandoffTestRecord }
@MainActor final class HandoffTestConversation {
    var currentConversationID=UUID()
    var messages=[AssistantMessage]()
    func flightOffers(for message:AssistantMessage)->[CtripFlightOffer] { message.flightOffers ?? [] }
}
@MainActor final class HandoffTestEngine { var currentRecord:HandoffTestRecord? }
@MainActor final class HandoffTestHistory { var records=[HandoffTestRecord]() }
@MainActor final class HandoffTestQueue { var items=[HandoffTestQueueItem]() }
@MainActor final class PhoneAgentViewModel {
    var conversation=HandoffTestConversation()
    var engine=HandoffTestEngine()
    var history=HandoffTestHistory()
    var taskQueue=HandoffTestQueue()
    var unifiedFocusedTaskID:UUID?
    var notice=""
}
