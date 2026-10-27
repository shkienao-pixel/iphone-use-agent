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
  conversation.paotuiPresentation={card,id in .init(isCurrent:card.conversationID==id,allowedActions:[.choose,.quote,.review,.confirm,.edit,.more])}
  var queryCount=0,choiceCount=0
  var textContext:PaotuiHostContext?,cardContext:PaotuiHostContext?
  var receivedInput:ConversationRoutingInput?
  conversation.unifiedRoute={input in .init(mode:.paotuiQuery,request:input.question,message:"")}
  conversation.paotuiQuery={ input,context in
   let id=context.conversationID
   textContext=context
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
  conversation.paotuiSelection={ _,_,context in
   cardContext=context
   choiceCount+=1
   return await withCheckedContinuation{pending=$0}
  }
  conversation.selectPaotui(card,.init(action:.choose,value:"address:1"))
  conversation.selectPaotui(card,.init(action:.choose,value:"address:1"))
  try await wait{pending != nil}
  expect(choiceCount==1,"Double-tapping the same card starts only one selection")
  expect(conversation.processingConversationIDs==[conversation.currentConversationID],"Native card actions use the same process-local request ownership as text")
  expect(textContext?.conversationID==cardContext?.conversationID && textContext?.requestID != cardContext?.requestID,"Text and native actions receive one explicit origin and distinct host request tokens")
  expect(conversation.messages.last?.role=="user" && conversation.messages.last?.text=="Fixture destination","Card choice is visible as user intent in dialogue")
  let oldID=conversation.currentConversationID
  conversation.newConversation()
  pending!.resume(returning:.init(text:"Late result",card:.init(conversationID:oldID,kind:"request",title:"Late result")))
  pending=nil
  try await Task.sleep(nanoseconds:30_000_000)
  expect(conversation.messages.isEmpty,"Late selection result cannot enter a different conversation")
  conversation.selectPaotui(card,.init(action:.choose,value:"address:1"))
  expect(choiceCount==1,"Old-conversation card cannot authorize a selection")
  let clearing=AssistantConversation(store:AssistantConversationStore(url:root.appendingPathComponent("clearing.json")))
  let clearingID=clearing.currentConversationID
  var hasPreparation=true
  clearing.paotuiPresentation={card,id in .init(isCurrent:hasPreparation && card.conversationID==id,allowedActions:hasPreparation ? [.quote,.confirm] : [])}
  var clearedIDs:[UUID]=[]
  clearing.onConversationCleared={clearedIDs.append($0);hasPreparation=false}
  clearing.unifiedRoute={input in .init(mode:.paotuiQuery,request:input.question,message:"")}
  clearing.paotuiQuery={ _,context in .init(text:"核对需求",card:.init(conversationID:context.conversationID,kind:"request",title:"核对需求")) }
  clearing.draft="帮我跑腿买水"
  expect(clearing.send(settings:settings,apiKey:"fixture",memories:memory),"Clear lifecycle starts from a real native card")
  try await wait{!clearing.loading}
  let clearingCard=clearing.messages.last!.paotuiCard!
  var clearingReply:CheckedContinuation<PaotuiChatReply,Never>?
  clearing.paotuiSelection={ _,_,_ in await withCheckedContinuation{clearingReply=$0} }
  clearing.selectPaotui(clearingCard,.init(action:.quote))
  try await wait{clearingReply != nil}
  clearing.clear()
  expect(clearedIDs==[clearingID],"Clear synchronously notifies business modules of the exact conversation")
  expect(clearing.currentConversationID==clearingID && clearing.messages.isEmpty,"Clearing retains chat identity while removing its content")
  clearingReply!.resume(returning:.init(text:"Late old quote",card:.init(conversationID:clearingID,kind:"quotes",title:"Late old quote")))
  clearingReply=nil
  try await Task.sleep(nanoseconds:30_000_000)
  expect(clearing.messages.isEmpty && !clearing.isCurrentPaotuiCard(clearingCard),"A cancelled card response cannot repopulate cleared chat")
  // Text work may finish offscreen. Its request and reply remain owned by A
  // even while B has an independently running request and an edited draft.
  let background=AssistantConversation(store:AssistantConversationStore(url:root.appendingPathComponent("background.json")))
  background.unifiedRoute={input in .init(mode:.paotuiQuery,request:input.question,message:"")}
  var pendingText:[UUID:CheckedContinuation<PaotuiChatReply,Never>]=[:]
  var contexts:[PaotuiHostContext]=[]
  background.paotuiQuery={_,context in
   contexts.append(context)
   return await withCheckedContinuation{pendingText[context.conversationID]=$0}
  }
  background.paotuiPresentation={card,id in .init(isCurrent:card.conversationID==id,allowedActions:[.quote,.confirm])}
  let originA=background.currentConversationID
  background.draft="A 的跑腿需求"
  expect(background.send(settings:settings,apiKey:"fixture",memories:memory),"Background A text accepted")
  try await wait{pendingText[originA] != nil}
  background.newConversation()
  let originB=background.currentConversationID
  background.draft="B 的跑腿需求"
  expect(background.send(settings:settings,apiKey:"fixture",memories:memory),"B may start while A runs")
  try await wait{pendingText[originB] != nil}
  background.draft="B 的新草稿"
  pendingText.removeValue(forKey:originA)!.resume(returning:.init(text:"A 的报价",card:.init(conversationID:originA,kind:"request",title:"A 的报价")))
  try await wait{!background.processingConversationIDs.contains(originA)}
  expect(background.currentConversationID==originB && background.loading && background.draft=="B 的新草稿","Background A completion preserves B selection, loading and draft")
  expect(background.messages.allSatisfy{!$0.text.contains("A 的报价")},"A reply never enters B messages")
  expect(background.conversations.first{$0.id==originA}?.messages.last?.text=="A 的报价","A completion is appended to its original archived record")
  pendingText.removeValue(forKey:originB)!.resume(returning:.init(text:"B 的报价",card:.init(conversationID:originB,kind:"request",title:"B 的报价")))
  try await wait{!background.loading}
  expect(background.openConversation(originA),"Same-process originating chat can reopen")
  let archivedCard=background.messages.last!.paotuiCard!
  expect(background.isCurrentPaotuiCard(archivedCard),"Reopening uses the live module presentation provider")
  let restart=AssistantConversation(store:AssistantConversationStore(url:root.appendingPathComponent("background.json")))
  expect(!restart.messages.isEmpty && !restart.isCurrentPaotuiCard(archivedCard),"Restarted persisted cards cannot regain action authority without a live module session")
  expect(contexts.count==2 && contexts.map(\.conversationID)==[originA,originB] && contexts[0].requestID != contexts[1].requestID,"Parallel module inputs carry exact originating chats and unique request tokens")

  // Explicit confirmation is foreground work. Navigation cancels its request,
  // and a non-cooperative late result cannot revive or cross the chat boundary.
  var confirmReply:CheckedContinuation<PaotuiChatReply,Never>?
  var confirmationContext:PaotuiHostContext?
  background.paotuiSelection={_,selection,context in
   expect(selection.action == .confirm,"Native final confirmation remains an explicit card action")
   confirmationContext=context
   return await withCheckedContinuation{confirmReply=$0}
  }
  background.selectPaotui(archivedCard,.init(action:.confirm))
  try await wait{confirmReply != nil}
  expect(background.loading && background.processingConversationIDs.contains(originA),"Native confirmation registers as a foreground LiveRequest")
  background.newConversation()
  expect(!background.processingConversationIDs.contains(originA),"Navigation cancels the original foreground confirmation request")
  confirmReply!.resume(returning:.init(text:"late native receipt"));confirmReply=nil
  try await Task.sleep(nanoseconds:30_000_000)
  expect(background.messages.isEmpty && background.conversations.first{$0.id==originA}?.messages.last?.text=="A 的报价","Late canceled native action publishes neither to B nor its old chat")
  expect(confirmationContext?.conversationID==originA && !contexts.map(\.requestID).contains(confirmationContext!.requestID),"Native confirmation binds the originating chat and a new request token")

  // The model-facing SessionSummary is revoked alongside forgotten history.
  let forgetting=AssistantConversation(store:AssistantConversationStore(url:root.appendingPathComponent("forgetting.json")))
  forgetting.paotuiSummary={id in .init(conversationID:id)}
  let summary=forgetting.paotuiRoutingSummary(for:forgetting.currentConversationID)
  expect(summary?["active"] as? Bool == true,"The host exposes a live read-only session summary")
  var approvedContexts:[String]=[]
  forgetting.unifiedRoute={input in approvedContexts.append(input.taskContext);return .init(mode:.paotuiQuery,request:input.question,message:"")}
  forgetting.paotuiQuery={_,_ in .init(text:"已收到需求")}
  forgetting.taskContext={"{\"tasks\":[],\"paotuiConversationActive\":true,\"paotuiSession\":{\"isActivePreparation\":true}}"}
  forgetting.draft="历史跑腿来源"
  expect(forgetting.send(settings:settings,apiKey:"fixture",memories:memory),"History source accepted")
  try await wait{!forgetting.loading}
  let forgottenID=forgetting.messages.first!.id
  memory.excludedMessageIDs=[forgottenID]
  forgetting.draft="排除历史后本轮问题"
  expect(forgetting.send(settings:settings,apiKey:"fixture",memories:memory),"History-filtered request accepted")
  try await wait{!forgetting.loading}
  let filtered=try JSONSerialization.jsonObject(with:Data(approvedContexts.last!.utf8)) as! [String:Any]
  expect(filtered["paotuiConversationActive"] as? Bool == false && filtered["paotuiSession"] is NSNull,"Excluded history revokes both active routing flag and module summary")
  memory.excludedMessageIDs=[]
  var requestedOrigins:[UUID]=[]
  forgetting.routingTaskContextInConversation={_,_,origin in requestedOrigins.append(origin);return "{}"}
  forgetting.draft="显式会话上下文"
  expect(forgetting.send(settings:settings,apiKey:"fixture",memories:memory),"Origin-bound context request accepted")
  try await wait{!forgetting.loading}
  expect(requestedOrigins==[forgetting.currentConversationID],"Routing context receives the submitted originating conversation explicitly")
  var price=PaotuiChatCard(conversationID:UUID(),kind:"quotes",title:"Fixture quote",deliveryFee:18)
  expect(price.total==nil,"Delivery fee alone is not a food total")
  price.goodsPrice=25
  expect(price.total==43,"Total exists only when both components are known")
  price.options=Array(repeating:.init(id:"duplicate",title:"bad"),count:2)
  expect(!price.valid,"Malformed persisted options cannot become card authority")
  print("PASS: \(checks) actual conversation host routing, inline choices, double-tap/cancel ownership and price completeness checks; no network")
 }
}
