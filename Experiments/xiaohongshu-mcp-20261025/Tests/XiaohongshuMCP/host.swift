import Foundation

@main struct HostChecks {
 static var checks = 0
 static func expect(_ value: Bool,_ label: String) { checks += 1; precondition(value,label) }
 @MainActor static func settle(_ condition: () -> Bool) async throws {
  for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
  fatalError("Host operation did not finish")
 }
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("xhs-host-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let conversation=AssistantConversation(store:AssistantConversationStore(url:root.appendingPathComponent("conversations.json")))
  let note=XHSNote(id:"0123456789abcdef01234567",title:"Fixture coffee",author:"Fixture author")
  let raw=#"{"action":"search","keyword":"咖啡"}"#
  conversation.unifiedRoute={ _ in .init(mode:.xiaohongshuQuery,request:raw,message:"") }
  var queries=0,choices=0
  conversation.xhsQuery={ query,id in
   expect(query==raw,"Structured provider query is preserved separately from raw human turn")
   queries += 1
   return .init(text:"Fixture search evidence",card:.init(conversationID:id,title:"Search",kind:"search",notes:[note]))
  }
  let settings=AgentSettings(),memories=MemoryStore()
  conversation.draft="搜索小红书咖啡"
  expect(conversation.send(settings:settings,apiKey:"fixture",memories:memories),"XHS conversation request starts")
  try await settle { !conversation.loading }
  expect(queries==1 && OfflineModel.shared.requests.isEmpty,"Native XHS route bypasses ordinary answer and phone GUI")
  let message=conversation.messages.last!,card=message.xhsCard!
  expect(conversation.isCurrentXHSCard(card) && !conversation.canRetry(message),"Current card can read, ordinary retry cannot change evidence")
  var gate: CheckedContinuation<XHSConversationReply,Never>?
  conversation.xhsSelection={ _,query in
   expect(query.noteID==note.id && query.action == .comments,"Button retains exact selected note and read intent")
   choices += 1
   return await withCheckedContinuation { gate=$0 }
  }
  conversation.selectXHS(card,.init(action:.comments,noteID:note.id))
  conversation.selectXHS(card,.init(action:.comments,noteID:note.id))
  try await settle { gate != nil }
  expect(choices==1,"Double tap dispatches exactly one read")
  expect(conversation.messages.last?.text == "读取评论：Fixture coffee","Read action is visible as human intent")
  conversation.newConversation()
  gate!.resume(returning:.init(text:"Late fixture result",card:.init(conversationID:card.conversationID,title:"Late",kind:"comments",notes:[note])))
  try await Task.sleep(nanoseconds:30_000_000)
  expect(conversation.messages.isEmpty,"Late callback cannot enter another conversation")
  conversation.selectXHS(card,.init(action:.detail,noteID:note.id))
  expect(choices==1,"Previous conversation card cannot authorize a new read")
  conversation.xhsQuery=nil;conversation.draft="再搜索"
  expect(conversation.send(settings:settings,apiKey:"fixture",memories:memories),"Missing connector attempt is bounded")
  try await settle { !conversation.loading }
  expect(conversation.messages.isEmpty && !conversation.error.isEmpty && OfflineModel.shared.requests.isEmpty,"Missing connector fails closed instead of inventing a model answer")
  let data=try JSONEncoder().encode(AssistantMessage(role:"assistant",text:"Fixture",xhsCard:card))
  let restored=try JSONDecoder().decode(AssistantMessage.self,from:data)
  expect(restored.xhsCard==card && restored.xhsCard?.valid == true,"Public card evidence round-trips through the actual message model")
  print("PASS: \(checks) actual XHS conversation host routing, current-card, double-tap, cancellation and missing-connector checks; offline only")
 }
}
