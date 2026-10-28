from pathlib import Path
import hashlib,json,sys
root,out=map(Path,sys.argv[1:])
def member(s,k):
 assert s.count(k)==1,(k,s.count(k))
 a=s.index(k); b=s.index('{',a)+1;depth=1
 while depth:
  depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
vm=(root/'PhoneAgent/PhoneAgentViewModel.swift').read_text(); cv=(root/'PhoneAgent/ContentView.swift').read_text()
p=out/'production/NavigationEnvironment.swift'; s=p.read_text()
s=s.replace('var running = false, releasing = false, paused = false','''var running = false, releasing = false, paused = false
    var hasCurrentTask: Bool { currentRecord != nil }
    var activityControlSessionID = UUID()
    func pause() { running = false; paused = true }
    func handoff() { pause() }''')
s=s.replace('var pendingConversationTask: NavigationPending?', 'var pendingConversationTask: ConversationTaskSubmission?')
old=member(s,'    @discardableResult func pauseTask() -> Bool')
extracted={k:member(vm,v) for k,v in {
'pauseTask':'    @discardableResult\n    func pauseTask(',
'haltQueue':'    private func haltQueue(',
'cancelVoice':'    private func cancelVoicePreparation(',
'controlContext':'    var conversationControlContext:',
'pendingTask':'    func pendingTaskForConversation(',
'route':'        conversation.unifiedRoute = { [weak self] input in',
}.items()}
s=s.replace(old,'\n'.join(extracted[k] for k in ['pauseTask','haltQueue','cancelVoice','controlContext','pendingTask']))
marker='    init(_ conversation: AssistantConversation) { self.conversation = conversation }'
s=s.replace(marker,marker+'''
    let memories = MemoryStore(), backgroundTasks = OfflineBackground(), contentStore = OfflineStopper()
    var settings = AgentSettings(), consentReady = true
    var pendingConsentStart = false, pendingConsentConversationTask: ConversationTaskSubmission?, pendingConsentAttachments: [ComposerAttachment] = []
    var preparingAutomatically = false, queueSwitching = false, queueRunning = false, manualBusy = false, calibrating = false
    var recordingAudioOwner: UUID?
    var automaticPreparationGeneration = UUID(), voiceGeneration = UUID(), queueGeneration = UUID(), conversationInteractionID = UUID()
    var queueOperation: Task<Void,Never>?, queueAdvance: Task<Void,Never>?, voicePreparation: Task<Void,Never>?, manual: Task<Void,Never>?
    var queueStatus = "", manualContinuationRequired = false
    var unifiedFocusedTaskID: UUID? { get { conversation.focusedTaskID } set { conversation.focusedTaskID = newValue } }
    func cancelAutomaticPreparation() { preparingAutomatically = false }
    func recoverableTask(_ id: UUID) -> PhoneTaskRecord? { nil }
    func handleVoiceCommand(_ command: VoiceCommand) async -> String { "not used" }
    func installBridge() {
        conversation.taskControlContext = { [weak self] in self?.conversationControlContext }
''' + extracted['route'] + '\n    }\n')
s=s.replace('@MainActor final class NavigationAttachmentDraft { var items: [ComposerAttachment] = [] }','''@MainActor final class NavigationAttachmentDraft { var items: [ComposerAttachment] = []; var importing = false; func clear() { items = [] } }''')
submit=member(cv,'    private func submitComposer()')
inputblocked=member(cv,'    private var inputBlocked: Bool')
s=s.replace('    func pressNewTask() { requestNewTask() }','''    let composerText = OfflineBinding()
    var composingSupplement = true, dictatedDraft: String?, voiceCommandTask: Task<Void,Never>?
    var amendmentDrafts: [UUID:String] = [:]
    var displayedRecord: PhoneTaskRecord? { model.engine.currentRecord }
    func sendForChecks(_ text: String) { composerText.wrappedValue = text; submitComposer() }
    var canInputForChecks: Bool { !inputBlocked }
'''+inputblocked+'\n'+submit+'\n    func pressNewTask() { requestNewTask() }')
s+='''
@MainActor final class OfflineStopper { func invalidatePreparations() {} }
@MainActor final class OfflineBinding { var wrappedValue = "" }
enum VoiceCommand { case unused; static func parse(_ text:String)->VoiceCommand? { nil } }
enum SettingsStore { static func apiKey(for endpoint:String)->String { "offline-unused" } }
@MainActor final class OfflineBackground { var sessions: [UUID:UUID] = [:]; func token(_ id:UUID)->UUID? { nil } }
@MainActor enum OfflineRoute { static var mode = ConversationRoute.Mode.supplement; static var captured: ConversationRoutingInput?; static var gate: CheckedContinuation<Void,Never>?; static var hold = false }
@MainActor struct UnifiedConversationRouter {
 let settings: AgentSettings, apiKey: String
 func route(input: ConversationRoutingInput) async throws -> ConversationRoute {
  OfflineRoute.captured = input
  if OfflineRoute.hold { await withCheckedContinuation { OfflineRoute.gate = $0 } }
  return ConversationRoute(mode: OfflineRoute.mode, request: input.question, message: "本地控制回执", taskID: input.selectedTaskID)
 }
}
'''
p.write_text(s)
b=out/'production/ModelBoundaries.swift'; text=b.read_text();text=text.replace('struct PhoneTaskRecord {','struct PhoneTaskRecord {\n    var executionLane: String? = nil');b.write_text(text)
(out/'extracted-members.json').write_text(json.dumps({'exact_vm_members_sha256':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in extracted.items()},'exact_submit_sha256':hashlib.sha256(submit.encode()).hexdigest(),'limits':'Actual submitComposer, navigation, pauseTask, haltQueue, cancelVoice, controlContext, whole unifiedRoute closure and AssistantConversation/store; SwiftUI Binding, physical engine/audio, model response are local synthetic boundaries. No product edits or service calls.'},indent=2)+'\n')
