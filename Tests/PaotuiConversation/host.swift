import Foundation

@main struct NativeChatHostChecks {
 static var checks=0
 static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
 @MainActor static func wait(_ condition:()->Bool) async throws {
  for _ in 0..<200 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
  fatalError("Bounded host operation did not finish")
 }
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("paotui-chat-host-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let conversation=AssistantConversation(store:AssistantConversationStore(url:root.appendingPathComponent("conversations.json")))
  var queryCount=0,choiceCount=0
  var receivedInput:ConversationRoutingInput?
  conversation.unifiedRoute={input in .init(mode:.paotuiQuery,request:input.question,message:"")}
  conversation.paotuiQuery={ input,id in
   receivedInput=input
   queryCount+=1
   return .init(text:"送到哪里？",card:.init(conversationID:id,kind:"addresses",title:"送到哪里？",options:[.init(id:"address:1",title:"Fixture destination")]))
  }
  let memory=MemoryStore();var settings=AgentSettings();settings.useMemories=true
  memory.reference="PAOTUI-APPROVED-MEMORY"
  let attachment=ComposerAttachment(name:"本轮.txt",kind:.text,byteCount:12,text:"本轮参考资料",imageJPEG:nil)
  conversation.draft="帮我跑腿买饭"
  expect(conversation.send(settings:settings,apiKey:"fixture",memories:memory,attachments:[attachment]),"Native business query accepted")
  try await wait{!conversation.loading}
  expect(queryCount==1 && OfflineModel.shared.requests.isEmpty,"Native errands bypasses ordinary answer and phone agent")
  expect(receivedInput?.memoryContext==memory.reference && receivedInput?.attachments==[attachment],"Native module receives the same approved memory and actual current attachment used for intent routing")
  let message=conversation.messages.last!,card=message.paotuiCard!
  expect(conversation.isCurrentPaotuiCard(card),"Address card is active in this conversation")
  expect(!conversation.canRetry(message),"Native order card cannot be regenerated as ordinary model text")
  var pending:CheckedContinuation<PaotuiChatReply,Never>?
  conversation.paotuiSelection={ _,_,id in
   choiceCount+=1
   return await withCheckedContinuation{pending=$0}
  }
  conversation.selectPaotui(card,.init(action:.choose,value:"address:1"))
  conversation.selectPaotui(card,.init(action:.choose,value:"address:1"))
  try await wait{pending != nil}
  expect(choiceCount==1,"Double-tapping the same card starts only one selection")
  expect(conversation.messages.last?.role=="user" && conversation.messages.last?.text=="Fixture destination","Card choice is visible as user intent in dialogue")
  let oldID=conversation.currentConversationID
  conversation.newConversation()
  pending!.resume(returning:.init(text:"Late result",card:.init(conversationID:oldID,kind:"request",title:"Late result")))
  pending=nil
  try await Task.sleep(nanoseconds:30_000_000)
  expect(conversation.messages.isEmpty,"Late selection result cannot enter a different conversation")
  conversation.selectPaotui(card,.init(action:.choose,value:"address:1"))
  expect(choiceCount==1,"Old-conversation card cannot authorize a selection")
  var price=PaotuiChatCard(conversationID:UUID(),kind:"quotes",title:"Fixture quote",deliveryFee:18)
  expect(price.total==nil,"Delivery fee alone is not a food total")
  price.goodsPrice=25
  expect(price.total==43,"Total exists only when both components are known")
  price.options=Array(repeating:.init(id:"duplicate",title:"bad"),count:2)
  expect(!price.valid,"Malformed persisted options cannot become card authority")
  print("PASS: \(checks) actual conversation host routing, inline choices, double-tap/cancel ownership and price completeness checks; no network")
 }
}
