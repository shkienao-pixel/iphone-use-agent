import Foundation
enum AgentError: Error { case message(String) }
struct HandoffTestLog { var title:String; var detail:String }
struct HandoffTestRecord { var id:UUID; var goal:String; var updatedAt:Date; var logs:[HandoffTestLog] }
struct HandoffTestQueueItem { var id:UUID; var record:HandoffTestRecord }
@MainActor final class FlightSelectionTestConversation {
    var currentConversationID = UUID()
    var messages = [AssistantMessage]()
    var flightQuery: ((String) async throws -> String)?
    private var generation = UUID()
    private var presentationOwners = [UUID]()
    // INSERT_PRODUCTION_LEASE
    func setRequestToken(_ value: UUID) { generation = value }
    func flightOffers(for message: AssistantMessage) -> [CtripFlightOffer] {
        CtripFlightParser.offers(message.text, query: message.flightQuery ?? "", at: message.createdAt)
    }
    @discardableResult func reportTaskHandoff(text:String,to id:UUID,in origin:UUID?,onlyIfUnlinked:Bool=true)->Bool {
        guard currentConversationID == origin, let index=messages.firstIndex(where:{$0.id==id}) else {return false}
        messages[index].text=text;return true
    }
}
@MainActor final class HandoffTestEngine { var currentRecord:HandoffTestRecord? }
@MainActor final class HandoffTestHistory { var records=[HandoffTestRecord]() }
@MainActor final class HandoffTestQueue { var items=[HandoffTestQueueItem]() }
@MainActor final class PhoneAgentViewModel {
    var conversation=FlightSelectionTestConversation()
    var engine=HandoffTestEngine()
    var history=HandoffTestHistory()
    var taskQueue=HandoffTestQueue()
    var unifiedFocusedTaskID:UUID?
    var notice=""
}
