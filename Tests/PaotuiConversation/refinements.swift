import Foundation

@MainActor final class PlanFixture {
 var value = "{}"
 var calls = 0
}
@main struct RefinementChecks {
 static var checks = 0
 static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
 @MainActor static func main() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-refinements-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let backend = Backend(), plan = PlanFixture()
  let store = MeituanPaotuiStore(receiptURL: root.appendingPathComponent("orders.json"), clientFactory: backend.client)
  try store.installCredential("offline-refinement-key")
  let controller = MeituanPaotuiConversation(store: store, planner: { _, _, _ in plan.calls += 1; return plan.value })
  let settings = AgentSettings(), id = UUID()
  func respond(_ text: String, _ json: String, _ conversation: UUID = id, history: [AssistantMessage] = []) async throws -> PaotuiChatReply {
   plan.value = json
   return try await controller.respond(question: text, history: history, conversationID: conversation, settings: settings, apiKey: "fixture")
  }
  func choose(_ reply: PaotuiChatReply, _ value: String, _ conversation: UUID = id) async throws -> PaotuiChatReply {
   try await controller.select(reply.card!, .init(action: .choose, value: value), conversationID: conversation)
  }
  func quote(_ reply: PaotuiChatReply, _ conversation: UUID = id) async throws -> PaotuiChatReply {
   try await controller.select(reply.card!, .init(action: .quote), conversationID: conversation)
  }
  var result = try await respond("只询价", #"{"service":"buy","goods":"鸡肉饭一份","store":"Fixture Kitchen","inquiryOnly":true,"remark":"少盐"}"#)
  result = try await choose(result, "address:2")
  result = try await choose(result, "poi:fixture-shop")
  expect(result.card?.remark == "少盐", "Requested purchase remark is visible for review")
  expect(result.card?.recipientContact?.contains("138****0000") == true && result.card?.purchaseAddress.contains("Fixture store") == true, "Review includes masked contact and full store address")
  result = try await quote(result)
  result = try await choose(result, result.card!.options[0].id)
  expect(result.card?.inquiryOnly == true && result.card?.canCreateOrder == false, "Inquiry-only requirement disables order creation")
  expect(result.text.contains("询价明细") && !result.text.contains("这会创建"), "Inquiry detail text never says an order will be created")
  do { _ = try await controller.select(result.card!, .init(action: .confirm), conversationID: id); fatalError("Inquiry submitted") } catch { checks += 1 }
  expect(backend.submissions.isEmpty, "Inquiry-only guard is enforced by the host, beyond button state")
  result = try await respond("确认", #"{"intent":"continue"}"#)
  expect(result.card?.kind == "request" && backend.submissions.isEmpty, "Typed confirmation cannot bypass the order card")
  result = try await respond("不要备注", #"{"edit":"remark"}"#)
  expect(result.card?.remark == "", "Conversation can explicitly clear a remark")
  result = try await respond("换个地址", #"{"edit":"recipient"}"#)
  expect(result.card?.kind == "addresses" && result.card?.recipientAddress == "", "Changing destination reopens inline address selection")
  let calls = plan.calls
  result = try await respond("第二个", "{}", history: [.init(role: "assistant", text: result.text, paotuiCard: result.card)])
  expect(plan.calls == calls && result.card?.kind == "places", "Chinese ordinal binds directly to this card's actual choice")
  result = try await choose(result, "poi:fixture-shop")
  expect(result.card?.inquiryOnly == true, "Address and merchant changes preserve inquiry-only scope")

  let foodID = UUID()
  var food = try await respond("点份外卖鸡肉饭，先不下单", #"{"intent":"ordinary_food","goods":"鸡肉饭一份","store":"Fixture Kitchen","inquiryOnly":true}"#, foodID)
  expect(food.card?.kind == "mode" && backend.submissions.isEmpty, "Ordinary food delivery requires an explicit service choice")
  food = try await choose(food, "buy", foodID)
  expect(food.card?.kind == "addresses" && food.card?.goods == "鸡肉饭一份" && food.card?.inquiryOnly == true, "Switching to supported errands retains the stated goods and inquiry scope")

  backend.addressCount = 14; try await store.loadAddresses()
  let pagingID = UUID()
  result = try await respond("送到地址1附近", #"{"service":"buy","goods":"水一瓶","nearby":true,"recipient":"Fixture address 1"}"#, pagingID)
  expect(result.card?.options.count == 3 && result.card?.hasMoreAddresses == true, "First address card is bounded and advertises more matching addresses")
  result = try await controller.select(result.card!, .init(action: .more), conversationID: pagingID)
  expect(result.card!.options.allSatisfy { $0.title.contains("Fixture address 1") }, "More addresses preserve the current search filter")
  expect(result.card!.options.contains { $0.id == "address:1" }, "Pagination reaches matching addresses beyond the first card")
  result = try await choose(result, "address:1", pagingID)
  expect(result.card?.kind == "request", "Selecting a later address completes request review")

  backend.addressCount = 2; try await store.loadAddresses()
  let sendID = UUID()
  result = try await respond("送一份文件", #"{"service":"send","goods":"文件一份","category":"document"}"#, sendID)
  expect(result.card?.kind == "weight" && backend.previews.count == 1, "Send request asks for actual weight before querying")
  result = try await respond("1", "{}", sendID, history: [.init(role: "assistant", text: result.text, paotuiCard: result.card)])
  expect(result.card?.kind == "addresses", "Numeric weight selection progresses to destination")
  result = try await choose(result, "address:2", sendID)
  result = try await choose(result, "address:1", sendID)
  expect(result.card?.itemWeight == 1 && result.card?.itemCategory == "文件", "Weight and category are visible in the reviewed request")
  result = try await quote(result, sendID)
  expect(result.card?.options.count == 2 && result.card?.total == 18, "Send cards compare actual normal/express fees with a complete delivery total")
  let goods = backend.previews.last!["goods"] as! [String: Any]
  expect(goods["goodsWeight"] as? Double == 1 && goods["goodTypes"] as? [Int] == [4], "Reviewed send weight/category reach the real production wire body")
  expect(!result.text.contains("商品费尚未确定"), "Send dialogue does not claim an unknown purchase cost")

  backend.deliveryFee = 120
  let highID = UUID()
  result = try await respond("买一瓶水", #"{"service":"buy","goods":"水一瓶","nearby":true}"#, highID)
  result = try await choose(result, "address:2", highID)
  result = try await quote(result, highID)
  result = try await choose(result, result.card!.options[0].id, highID)
  result = try await controller.select(result.card!, .init(action: .confirm), conversationID: highID)
  expect(result.text.contains("超过 100") && backend.submissions.isEmpty, "High courier fee requires a second distinct confirmation")
  result = try await quote(result, highID)
  result = try await choose(result, result.card!.options[0].id, highID)
  result = try await controller.select(result.card!, .init(action: .confirm), conversationID: highID)
  expect(result.text.contains("超过 100") && backend.submissions.isEmpty, "A refreshed quote never inherits prior high-fee acceptance")
  result = try await controller.select(result.card!, .init(action: .confirm), conversationID: highID)
  expect(backend.submissions.count == 1 && result.card?.kind == "receipt", "Only the new card's explicit second confirmation submits")
  backend.failSubmit = true
  result = try await respond("再买一瓶水", #"{"intent":"new","service":"buy","goods":"水一瓶","nearby":true}"#, highID)
  result = try await choose(result, "address:2", highID)
  result = try await quote(result, highID)
  result = try await choose(result, result.card!.options[0].id, highID)
  result = try await controller.select(result.card!, .init(action: .confirm), conversationID: highID)
  result = try await controller.select(result.card!, .init(action: .confirm), conversationID: highID)
  expect(store.hasUnresolvedSubmission && backend.submissions.count == 2, "Lost submission response is retained as uncertain")
  expect(result.card?.orderURL == "https://i.meituan.com/", "Uncertain order never links to an older successful order")
  result = try await respond("只查询", #"{"inquiryOnly":true}"#, highID)
  result = try await quote(result, highID)
  expect(result.card?.deliveryFee == 120 && result.card?.canCreateOrder == false, "Read-only quotes remain available while earlier submission needs review")

  backend.alternateCity = true; try await store.loadAddresses()
  let cityID = UUID()
  result = try await respond("买水", #"{"service":"buy","goods":"水一瓶","store":"Fixture Kitchen","recipient":"Fixture address 2"}"#, cityID)
  expect(backend.searchRequests.last?["city"] as? String == "深圳", "Search derives city from the actual destination")
  result = try await choose(result, "poi:fixture-shop", cityID)
  result = try await respond("换到北京的地址", #"{"recipient":"Fixture address 1 101"}"#, cityID)
  expect(result.card?.kind == "places" && backend.searchRequests.last?["city"] as? String == "北京", "New destination discards prior merchant and uses its own city")
  result = try await choose(result, "poi:fixture-shop", cityID)
  let previewCount = backend.previews.count
  do { _ = try await quote(result, cityID); fatalError("Cross-city quote accepted") } catch { checks += 1 }
  expect(backend.previews.count == previewCount, "Cross-city mismatch is caught before a quote request")
  do { _ = try await respond("变更", #"{"intent":"unexpected"}"#, cityID); fatalError("Unknown intent accepted") } catch { checks += 1 }
  do { _ = try await respond("变更", #"{"weight":-1}"#, cityID); fatalError("Invalid weight accepted") } catch { checks += 1 }
  do { _ = try await respond("变更", #"{"goods":"null"}"#, cityID); fatalError("String null accepted") } catch { checks += 1 }
  var legacy = PaotuiChatCard(conversationID: UUID(), kind: "confirm", title: "Fixture")
  let legacyData = try JSONEncoder().encode(legacy)
  legacy = try JSONDecoder().decode(PaotuiChatCard.self, from: legacyData)
  expect(legacy.valid && legacy.inquiryOnly == nil && legacy.validUntil == nil, "Earlier saved cards remain readable")
  legacy.validUntil = Date(timeIntervalSince1970: 100)
  expect(legacy.expired(at: Date(timeIntervalSince1970: 101)), "Expiration is computed from the bound quote deadline")
  print("PASS: \(checks) conversation refinement checks: inquiry scope, address changes/pagination, weight, city, quote expiry, high fees and uncertain receipts; synthetic backend only")
 }
}
