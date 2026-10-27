import Foundation
@MainActor final class Probe {
 var calls=0
 func invalidate(){calls += 1}
 func invalidatePreparations(){calls += 1}
 func stop(){calls += 1}
 func cancel(){calls += 1}
 func hasUnresolvedWrite(taskID:UUID)->Bool {false}
}
@MainActor final class SessionEngine {
 var currentRecord:PhoneTaskRecord?;var hasCurrentTask=false;var running=false;var releasing=false;var stopCount=0
 func stop(){stopCount += 1;running=false}
 func pause(){running=false}
 func handoff(){running=false}
 func appendConversationReference(_ value:String)->Bool{true}
}
@MainActor final class SessionHistory {var records=[PhoneTaskRecord]()}
@MainActor final class Queue {
 struct Item {enum State {case waiting,paused,cancelled};var id=UUID();var resumable=true;var state:State = .waiting}
 var items=[Item]()
}
@MainActor final class SessionBackground {
 struct Origin {let conversationID:UUID;let messageID:UUID}
 var records=[PhoneTaskRecord]();var tokens=[UUID:UUID]()
 var sessions:[UUID:UUID]{tokens}
 func token(_ id:UUID)->UUID? {tokens[id]}
 func pause(_ id:UUID,expected:UUID?)throws{}
 func stop(_ id:UUID,expected:UUID?)throws{}
 func resume(_ id:UUID,settings:AgentSettings,expected:UUID?)throws{}
 func supplement(_ id:UUID,text:String,reference:String,settings:AgentSettings,expected:UUID?)throws{}
 func submit(goal:String,settings:AgentSettings,attachments:[ComposerAttachment],reference:String,origin:Origin)throws->UUID{UUID()}
}
@MainActor enum SettingsStore {static func apiKey(for endpoint:String)->String {"offline"}}
@MainActor struct UnifiedConversationRouter {
 let settings:AgentSettings;let apiKey:String
 static var handler:((ConversationRoutingInput) async throws -> ConversationRoute)?
 func route(input:ConversationRoutingInput) async throws ->ConversationRoute {try await Self.handler!(input)}
}
@MainActor final class PhoneAgentViewModel {
 let conversation:AssistantConversation;let memories=MemoryStore()
 let engine=SessionEngine(),history=SessionHistory(),backgroundTasks=SessionBackground(),taskQueue=Queue()
 let assistiveTouchVerification=Probe(),contentStore=Probe(),liveCamera=Probe(),camera=Probe(),speech=Probe(),tools=Probe()
 var settings=AgentSettings(),consentReady=true,modelReady=true
 var queueGeneration=UUID()
 var recoverable=[UUID:PhoneTaskRecord]()
 var pendingConversationTask:ConversationTaskSubmission?,pendingConsentConversationTask:ConversationTaskSubmission?
 var pendingConsentStart=false,pendingConsentAttachments=[ComposerAttachment]()
 var preparingAutomatically=false,queueSwitching=false,manualBusy=false,calibrating=false,queueRunning=false,showPrivacyConsent=false
 var voicePending=false,manualContinuationRequired=false,voiceMode:String?,notice="",goal=""
 var manual:Task<Void,Never>?,cancelCalibration:(()->Void)?
 var conversationControlContext=ConversationControlContext(taskID:nil,engineSessionID:UUID(),preparationID:UUID(),voiceID:UUID(),queueID:UUID(),interactionID:UUID())
 var screenQueueWaiting:[Queue.Item]{taskQueue.items}
 init(_ conversation:AssistantConversation){self.conversation=conversation}
 func recoverableTask(_ id:UUID)->PhoneTaskRecord?{recoverable[id]}
 func continueTask(_ id:UUID)->Bool{true}
 func cancelAutomaticPreparation(){preparingAutomatically=false}
 func haltQueue(_ text:String){}
 func cancelVoicePreparation(message:String?=nil){voicePending=false}
 func queueConversationScreenTask(_ route:ConversationRoute)->UUID?{nil}
 func openConversationFlight(_ route:ConversationRoute,replyID:UUID,conversationID:UUID){
  preconditionFailure("Flight opening is covered by FlightSelection and CtripHandoff, outside this session-isolation fixture")
 }
 func startAgent(attachments:[ComposerAttachment],conversationTask:ConversationTaskSubmission?)->Bool{false}
 func supplementTask(_ text:String)->String{""}
 func resumeVoiceTask(expectedContext:ConversationControlContext?)async->String{""}
 func resumeScreenQueueTask(_ id:UUID)->Bool{false}
