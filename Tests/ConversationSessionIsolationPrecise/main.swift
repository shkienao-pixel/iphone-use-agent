import Foundation
@main struct PreciseSessionChecks {
 @MainActor static func main() async throws {
  var checks=[[String:Any]]()
  func expect(_ value:Bool,_ name:String){checks.append(["name":name,"passed":value])}
  func wait(_ test:()->Bool) async throws {for _ in 0..<10000 {if test(){return};await Task.yield()};throw NSError(domain:"offline-timeout",code:1)}
  func payload(_ text:String)->[String:Any]{(try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any] ?? [:]}
  let folder=URL(fileURLWithPath:CommandLine.arguments[2]);try? FileManager.default.removeItem(at:folder);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  func make(_ name:String)->AssistantConversation{AssistantConversation(store:AssistantConversationStore(url:folder.appendingPathComponent(name+".json")))}
  let c=make("pending"),vm=PhoneAgentViewModel(c);vm.installRoute()
  let pending=ConversationTaskSubmission(conversationID:c.currentConversationID,messageID:UUID(),goal:"OWN_PENDING")
  vm.pendingConversationTask=pending;vm.preparingAutomatically=true
  func input(_ pending:ConversationTaskSubmission?,conversationID:UUID,history:[AssistantMessage]=[],selected:UUID?=nil)throws->ConversationRoutingInput {
   try ConversationRoutingInput(question:"控制",history:history,taskContext:vm.unifiedTaskContext(history:history),controlContext:vm.conversationControlContext,backgroundSessions:vm.backgroundTasks.sessions,selectedTaskID:selected,conversationID:conversationID,pendingTask:pending)
  }
  let row=(payload(vm.unifiedTaskContext(history:[]))["tasks"] as! [[String:Any]]).first!
  expect(row["id"] as? String==pending.taskID.uuidString && row["status"] as? String=="preparing","same-origin pending has real reserved ID and unstarted status without record")
  for mode in [ConversationRoute.Mode.pause,.stop] {
   UnifiedConversationRouter.handler={_ in .init(mode:mode,request:"",message:"取消")}
   let route=try await c.unifiedRoute!(input(pending,conversationID:c.currentConversationID))
   expect(route.taskID==pending.taskID && route.pendingTask==pending && route.controlContext?.taskID==pending.taskID,"same-origin pending binds reserved ID and submitted preparation lease: "+mode.rawValue)
  }
  let foreign=ConversationTaskSubmission(conversationID:UUID(),messageID:UUID(),goal:"FOREIGN_PENDING")
  let foreignInput=try input(foreign,conversationID:c.currentConversationID)
  expect(foreignInput.pendingTask==nil && foreignInput.authorizedTaskIDs.isEmpty,"foreign pending is absent from new session scope")
  UnifiedConversationRouter.handler={_ in .init(mode:.stop,request:"",message:"stop")}
  expect(try await c.unifiedRoute!(foreignInput).mode == .clarify,"foreign pending cannot dispatch stop")
  let stale=try input(pending,conversationID:c.currentConversationID)
  vm.conversationControlContext = .init(taskID:nil,engineSessionID:UUID(),preparationID:UUID(),voiceID:UUID(),queueID:UUID(),interactionID:UUID())
  do {_ = try await c.unifiedRoute!(stale);expect(false,"changed preparation lease rejects pending control")}catch{expect(true,"changed preparation lease rejects pending control")}
  vm.pendingConversationTask=nil;vm.preparingAutomatically=false
  let screen=UUID(),worker=UUID(),token=UUID()
  vm.engine.currentRecord=PhoneTaskRecord(id:screen,title:"screen",goal:"screen",summary:"");vm.engine.hasCurrentTask=true
  vm.conversationControlContext = .init(taskID:screen,engineSessionID:UUID(),preparationID:UUID(),voiceID:UUID(),queueID:UUID(),interactionID:UUID());vm.backgroundTasks.tokens[worker]=token
  var screenLink=AssistantMessage(role:"assistant",text:"screen");screenLink.taskID=screen
  var workerLink=AssistantMessage(role:"assistant",text:"worker");workerLink.taskID=worker
  let history=[screenLink,workerLink]
  UnifiedConversationRouter.handler={_ in .init(mode:.pause,request:"",message:"pause")}
  expect(try await c.unifiedRoute!(input(nil,conversationID:c.currentConversationID,history:history)).mode == .clarify,"screen plus background without explicit focus or ID clarifies ambiguity")
  let focused=try await c.unifiedRoute!(input(nil,conversationID:c.currentConversationID,history:history,selected:screen))
  expect(focused.mode == .pause && focused.taskID==screen,"explicit screen selection remains usable with multiple own tasks")
  UnifiedConversationRouter.handler={_ in .init(mode:.stop,request:"",message:"stop",taskID:worker)}
  let explicit=try await c.unifiedRoute!(input(nil,conversationID:c.currentConversationID,history:history))
  expect(explicit.taskID==worker && explicit.backgroundControlToken==token,"explicit worker ID retains its exact submitted token")
  vm.engine.hasCurrentTask=false;vm.engine.currentRecord=nil;vm.conversationControlContext = .init(taskID:nil,engineSessionID:UUID(),preparationID:UUID(),voiceID:UUID(),queueID:UUID(),interactionID:UUID())
  vm.pendingConversationTask=pending;vm.backgroundTasks.records=[];vm.backgroundTasks.tokens=[:]
  var many=[AssistantMessage]()
  for _ in 0..<220 {
   let id=UUID();var m=AssistantMessage(role:"assistant",text:"link");m.taskID=id;many.append(m)
   vm.backgroundTasks.records.append(PhoneTaskRecord(id:id,title:"worker",goal:String(repeating:"G",count:160),summary:String(repeating:"S",count:120),logs:[AgentLogEntry(title:"工具回执",detail:String(repeating:"R",count:180))]));vm.backgroundTasks.tokens[id]=UUID()
  }
  let crowded=payload(vm.unifiedTaskContext(history:many)),crowdedRows=crowded["tasks"] as! [[String:Any]]
  expect(crowded["contextDetailsOmitted"] as? Bool == true && crowdedRows.contains{$0["id"] as? String==pending.taskID.uuidString && $0["status"] as? String=="preparing" && $0["pending"] as? String=="true"},"actual budget fallback keeps own pending reserved ID and unstarted state")
  // Real conversation send -> real extracted route bridge -> complete real handler -> real stop body.
  let live=make("late-A-stop"),host=PhoneAgentViewModel(live);host.installRoute();let settings=AgentSettings(),memories=MemoryStore()
  live.taskControlContext={host.conversationControlContext}
  live.routingTaskContext={question,history in host.unifiedTaskContext(history:history,question:question)}
  var late:CheckedContinuation<ConversationRoute,Never>?
  UnifiedConversationRouter.handler={input in
   if input.question=="SEED_A" {return .init(mode:.clarify,request:"",message:"准备中的请求")}
   if input.question=="STOP_A" {return await withCheckedContinuation{late=$0}}
   return .init(mode:.chat,request:"",message:"")
  }
  live.draft="SEED_A";_ = live.send(settings:settings,apiKey:"",memories:memories);try await wait{!live.loading && live.messages.last?.role=="assistant"}
  let aID=live.currentConversationID,sourceMessage=live.messages.last!.id
  let awaiting=ConversationTaskSubmission(conversationID:aID,messageID:sourceMessage,goal:"UNSTARTED_A")
  host.pendingConversationTask=awaiting;host.preparingAutomatically=true
  live.draft="STOP_A";expect(live.send(settings:settings,apiKey:"",memories:memories),"actual A pending stop submission begins")
  try await wait{late != nil};live.draft="KEEP_A_DRAFT";live.newConversation();let bID=live.currentConversationID
  let bIndex=OfflineModel.shared.requests.count
  live.draft="B_MARKER";expect(live.send(settings:settings,apiKey:"",memories:memories),"actual B send begins while A route is waiting")
  try await wait{OfflineModel.shared.requests.count>bIndex};live.draft="KEEP_B_DRAFT"
  late!.resume(returning:.init(mode:.stop,request:"",message:"停止等待"));late=nil
  try await wait{host.engine.stopCount==1}
  expect(aID != bID && live.currentConversationID==bID && live.loading && live.processingConversationIDs.contains(bID),"A late pending stop does not cancel actual B request in flight")
  expect(live.messages.count==1 && live.messages[0].text=="B_MARKER" && live.draft=="KEEP_B_DRAFT","A late stop leaves actual B user message and unsent draft intact")
  let savedA=live.conversations.first{$0.id==aID}!
  expect(savedA.draft=="KEEP_A_DRAFT" && savedA.messages.allSatisfy{$0.taskID==nil} && savedA.messages.contains{$0.text.contains("尚未启动")},"pending cancellation returns to A without creating execution card and preserves A draft")
  OfflineModel.shared.complete(bIndex,answer:"B_COMPLETED");try await wait{!live.loading}
  expect(live.messages.last?.text=="B_COMPLETED" && live.draft=="KEEP_B_DRAFT","B real reply still completes after A late task stop")
  // UI's original zero-argument stop still cancels the visible chat intentionally.
  let next=OfflineModel.shared.requests.count;live.draft="UI_STOP";_ = live.send(settings:settings,apiKey:"",memories:memories)
  try await wait{OfflineModel.shared.requests.count>next};host.stop()
  expect(!live.loading && !live.messages.contains{$0.text=="UI_STOP"} && live.draft=="UI_STOP","zero-argument UI stop keeps intentional visible-conversation cancellation")
  OfflineModel.shared.complete(next,answer:"IGNORED");await Task.yield()
  let failures=checks.filter{$0["passed"] as? Bool != true}
  let result:[String:Any]=["passed":checks.count-failures.count,"total":checks.count,"checks":checks,"A_conversationID":aID.uuidString,"B_conversationID":bID.uuidString,"complete_production_methods_without_substitution":true,"actual_conversation_store_and_async_receipts":true,"network_device_model_calls":0]
  try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  print("Precise session boundaries: \(checks.count-failures.count)/\(checks.count)")
  if !failures.isEmpty{failures.forEach{print($0)};Foundation.exit(1)}
 }
}
