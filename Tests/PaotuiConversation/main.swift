import Foundation

@main struct ConversationChecks {
 static var checks=0
 static func expect(_ condition:Bool,_ text:String){checks+=1;precondition(condition,text)}
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("paotui-dialog-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let backend=Backend(),store=MeituanPaotuiStore(receiptURL:root.appendingPathComponent("orders.json"),clientFactory:{backend.client($0)})
  try store.installCredential("offline-fixture-credential")
  var plan="{\"intent\":\"continue\"}",modelCalls=0
  let controller=MeituanPaotuiConversation(store:store,planner:{ _,_,_ in modelCalls+=1;return plan })
  let id=UUID(),settings=AgentSettings()
  var result=try await controller.respond(question:"帮我跑腿",history:[],conversationID:id,settings:settings,apiKey:"fixture")
  expect(result.card?.kind=="mode","Vague request asks service in conversation")
  result=try await controller.select(result.card!,.init(action:.choose,value:"buy"),conversationID:id)
  expect(result.card?.kind=="info","Missing goods triggers dialogue question")
  plan="{\"intent\":\"continue\",\"service\":\"buy\",\"goods\":\"鸡肉饭一份\",\"store\":\"Fixture Kitchen\"}"
  result=try await controller.respond(question:"Fixture Kitchen鸡肉饭一份",history:[],conversationID:id,settings:settings,apiKey:"fixture")
  expect(result.card?.kind=="addresses" && result.card!.options.count==2,"Actual saved-address choices appear in conversation")
  expect(result.card!.options.allSatisfy{!$0.detail.contains("13800000000")},"Address cards mask phone")
  let addressCard=result.card!
  let before=modelCalls
  result=try await controller.respond(question:"2",history:[AssistantMessage(role:"assistant",text:result.text,paotuiCard:addressCard)],conversationID:id,settings:settings,apiKey:"fixture")
  expect(modelCalls==before && result.card?.kind=="places","Typed ordinal selects actual card without model reconstruction")
  result=try await controller.select(result.card!,.init(action:.choose,value:"poi:fixture-shop"),conversationID:id)
  expect(result.card?.kind=="request" && backend.previews.isEmpty,"Complete request is reviewed before quote request")
  result=try await controller.select(result.card!,.init(action:.quote),conversationID:id)
  expect(result.card?.kind=="quotes" && result.card?.deliveryFee==18,"Quote card uses actual fee")
  expect(result.card?.goodsPrice==nil && result.card?.total==nil,"Unknown food price never becomes fake total")
  expect(backend.submissions.isEmpty,"Information and quote clicks cannot create order")
  result=try await controller.select(result.card!,.init(action:.choose,value:result.card!.options[0].id),conversationID:id)
  expect(result.card?.kind=="confirm" && backend.submissions.isEmpty,"Quote selection opens separate final chat confirmation")
  let stale=result.card!
  plan="{\"intent\":\"continue\",\"goods\":\"鸡肉饭两份\"}"
  result=try await controller.respond(question:"换成两份",history:[],conversationID:id,settings:settings,apiKey:"fixture")
  expect(result.card?.kind=="request","Correction returns to request review")
  do {_=try await controller.select(stale,.init(action:.confirm),conversationID:id);fatalError("Stale confirmation accepted")}catch{checks+=1}
  expect(backend.submissions.isEmpty,"Changed request cannot submit old quote")
  result=try await controller.select(result.card!,.init(action:.quote),conversationID:id)
  result=try await controller.select(result.card!,.init(action:.choose,value:result.card!.options[0].id),conversationID:id)
  let finalCard=result.card!
  do {_=try await controller.select(finalCard,.init(action:.confirm),conversationID:UUID());fatalError("Other conversation accepted")}catch{checks+=1}
  let restarted=MeituanPaotuiConversation(store:store)
  do {_=try await restarted.select(finalCard,.init(action:.confirm),conversationID:id);fatalError("Persisted card acquired authority after restart")}catch{checks+=1}
  result=try await controller.select(finalCard,.init(action:.confirm),conversationID:id)
  expect(result.card?.kind=="receipt" && backend.submissions.count==1,"Only explicit current chat confirmation submits once")
  expect(result.card?.orderURL.flatMap(URL.init(string:))?.lastPathComponent=="fixture-order-created","Receipt has actual order link")
  let encoded=try JSONEncoder().encode(result.card!)
  let text=String(data:encoded,encoding:.utf8)!
  expect(!text.contains("fixture-payment") && !text.contains("fixture-credential") && !text.contains("13800000000"),"Persisted chat cards contain no secrets")
  do {_=try await controller.select(finalCard,.init(action:.confirm),conversationID:id);fatalError("Duplicate card accepted")}catch{checks+=1}
  expect(backend.submissions.count==1,"Duplicate confirmation cannot repeat order")
  print("PASS: \(checks) production conversational slots, address/POI cards, unknown prices, correction and confirmation ownership checks; synthetic backend only")
 }
}
