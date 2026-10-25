import Foundation

enum AgentError: LocalizedError {
 case message(String)
 var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
enum ConnectionCredentialStore {
 static var values: [String:String] = [:]
 static func read(_ key: String) -> String { values[key] ?? "" }
 static func save(_ value: String, account: String) throws { values[account] = value }
}
@MainActor final class Backend {
 let id = "0123456789abcdef01234567"
 var loggedIn = true, mismatchedNote = false, fail = false, echoKey = false
 var requests: [URLRequest] = [], calls: [[String: Any]] = []
 var gate: CheckedContinuation<Void, Never>?
 var hold = false
 func client(_ endpoint: URL, _ token: String) -> XiaohongshuMCPClient {
  .init(endpoint: endpoint, token: token, transport: { request in
   self.requests.append(request)
   if self.fail { throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "SECRET-NETWORK-DETAIL"]) }
   let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
   let method = input["method"] as! String
   if method == "notifications/initialized" { return (Data(), HTTPURLResponse(url: request.url!,statusCode:204,httpVersion:nil,headerFields:nil)!) }
   let result: [String: Any]
   if method == "initialize" { result = ["protocolVersion":"2025-11-25","capabilities":["tools":[:]],"serverInfo":["name":"fixture","version":"1"]] }
   else {
    let params = input["params"] as! [String:Any], name = params["name"] as! String
    self.calls.append(params)
    if self.hold { await withCheckedContinuation { self.gate = $0 } }
    let payload: [String: Any]
    switch name {
    case "check_login_status":
     result = ["content":[["type":"text","text":self.loggedIn ? "✅ 已登录\n用户名: fixture" : "❌ 未登录"]]]
     return try self.response(request,input,result)
    case "get_login_qrcode":
     result = ["content":[["type":"image","mimeType":"image/png","data":Data([137,80,78,71,13,10,26,10,0]).base64EncodedString()]]]
     return try self.response(request,input,result)
    case "search_feeds":
     payload = ["feeds":[["modelType":"note","id":self.id,"xsecToken":"PRIVATE-NOTE-ACCESS-REF","noteCard":["displayTitle":"Fixture coffee","user":["nickname":"Fixture author"]]], ["modelType":"hot_query","id":"noise"]],"count":2]
    case "get_feed_detail":
     payload = ["feed_id":self.id,"data":["note":["noteId":self.mismatchedNote ? "ffffffffffffffffffffffff" : self.id,"title":"Fixture coffee","desc":"正文，PRIVATE-NOTE-ACCESS-REF 不能进入记录","user":["nickname":"Fixture author"]],"comments":["hasMore":true,"cursor":"PRIVATE-CURSOR","list":[["id":"comment-1","content":"第一条评论","userInfo":["nickname":"Reader"],"subComments":[["id":"reply-1","content":"回复正文","userInfo":["nickname":"Author"]]]],["id":"comment-1","content":"Duplicate"]]]]]
    default: fatalError("Unexpected MCP tool " + name)
    }
    let value = String(data: try JSONSerialization.data(withJSONObject:payload),encoding:.utf8)!
    result = ["content":[["type":"text","text":self.echoKey ? token : value]]]
   }
   return try self.response(request,input,result)
  })
 }
 func response(_ request: URLRequest,_ input: [String:Any],_ result: [String:Any]) throws -> (Data,HTTPURLResponse) {
  (try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":input["id"]!,"result":result]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Mcp-Session-Id":"fixture-session"])!)
 }
}

@main struct Checks {
 static var count = 0
 static func expect(_ value: Bool,_ label: String) { count += 1; precondition(value,label) }
 static func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Invalid request accepted") } catch { count += 1 } }
 @MainActor static func main() async throws {
  for raw in ["http://example.org/mcp","https://u:p@example.org/mcp","https://example.org/mcp?token=key","https://example.org/other","https://example.org/mcp#x"] {
   rejects { _ = try XiaohongshuMCPClient.endpoint(raw) }
  }
  let endpoint = try XiaohongshuMCPClient.endpoint("https://mcp.example.org/mcp")
  expect(endpoint.host == "mcp.example.org","Custom authenticated HTTPS MCP endpoint")
  for raw in [#"{"action":"publish","keyword":"x"}"#, #"{"action":"search"}"#, #"{"action":"detail","noteID":"made-up"}"#, #"{"action":"search","keyword":"x","token":"override"}"#] { rejects { _ = try XHSReadQuery.parse(raw) } }
  let backend = Backend(), defaults = UserDefaults(suiteName:"xhs-test-"+UUID().uuidString)!
  let store = XiaohongshuMCPStore(defaults:defaults,factory:backend.client)
  let flow = XiaohongshuMCPConversation(store:store), id = UUID()
  let missing = try await flow.run(.init(action:.search,keyword:"咖啡"),conversationID:id)
  expect(missing.card == nil && backend.calls.isEmpty,"Unconfigured query explains connection without network")
  try store.save(endpoint:endpoint.absoluteString,token:"fixture-key-private")
  expect(store.configured && !store.ready,"Saving a key does not claim account login")
  await store.checkLogin()
  expect(store.ready,"Only actual positive login tool response confirms session")
  var reply = try await flow.run(.init(action:.search,keyword:"咖啡"),conversationID:id)
  expect(reply.card?.notes.count == 1 && reply.card?.notes[0].title == "Fixture coffee","Search parses real MCP schema and ignores non-note cards")
  expect(backend.calls.last?["name"] as? String == "search_feeds","Search tool dispatch is fixed")
  expect(backend.requests.allSatisfy { $0.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-key-private" && $0.url?.query == nil },"Credential stays in header, never URL")
  expect(backend.requests.dropFirst().first?.value(forHTTPHeaderField:"MCP-Protocol-Version") == "2025-11-25","Negotiated protocol retained")
  let search = reply.card!
  reply = try await flow.select(search,query:.init(action:.detail,noteID:backend.id))
  expect(reply.card?.kind == "detail" && reply.card?.notes[0].body.contains("正文") == true,"Detail returns body from actual selected note")
  expect(reply.card?.comments.count == 2 && reply.card?.comments[1].reply == true,"Comments and replies are de-duplicated")
  expect(reply.card?.coverage.contains("已加载范围") == true,"Comment partial coverage stays explicit")
  let arguments = backend.calls.last?["arguments"] as! [String:Any]
  expect(arguments["xsec_token"] as? String == "PRIVATE-NOTE-ACCESS-REF","Actual search access ref is retained privately for detail")
  let archive = String(data:try JSONEncoder().encode(reply.card!),encoding:.utf8)!
  expect(!archive.contains("fixture-key-private") && !archive.contains("PRIVATE-NOTE-ACCESS-REF") && !archive.contains("PRIVATE-CURSOR"),"Saved cards contain no API credential, access ref or comment cursor")
  expect(!reply.text.contains("PRIVATE-NOTE-ACCESS-REF"),"Evidence text for model history removes private access ref")
  let before = backend.calls.count
  do { _ = try await flow.select(search,query:.init(action:.comments,noteID:backend.id));fatalError("Old card accepted") } catch { count += 1 }
  expect(backend.calls.count == before,"Old card cannot dispatch another read")
  reply = try await flow.select(reply.card!,query:.init(action:.comments,noteID:backend.id))
  let commentsArgs = backend.calls.last?["arguments"] as! [String:Any]
  expect(commentsArgs["limit"] as? Int == 20 && commentsArgs["load_all_comments"] as? Bool == true,"Explicit comments read is capped at 20 top-level comments")
  do { _ = try await flow.run(.init(action:.detail,noteID:backend.id),conversationID:UUID());fatalError("Cross conversation ref accepted") } catch { count += 1 }
  let restarted = XiaohongshuMCPConversation(store:store)
  do { _ = try await restarted.select(reply.card!,query:.init(action:.detail,noteID:backend.id));fatalError("Archived card acquired authority") } catch { count += 1 }
  backend.mismatchedNote = true
  do { _ = try await flow.run(.init(action:.detail,noteID:backend.id),conversationID:id);fatalError("Wrong note accepted") } catch { count += 1 }
  backend.mismatchedNote = false; backend.echoKey = true
  do { _ = try await flow.run(.init(action:.search,keyword:"x"),conversationID:id);fatalError("Credential echo accepted") } catch { count += 1 }
  backend.echoKey = false; backend.fail = true
  do { _ = try await flow.run(.init(action:.search,keyword:"x"),conversationID:id);fatalError("Network failure accepted") } catch { expect(!error.localizedDescription.contains("SECRET"),"Raw transport errors never reach the UI") }
  backend.fail = false; backend.loggedIn = false
  await store.checkLogin(); expect(!store.ready,"Negative login result revokes readiness")
  await store.loginQRCode(); expect(store.qrImage != nil && !store.ready,"QR generation is not a login success")
  backend.loggedIn = true; await store.checkLogin(); expect(store.ready && store.qrImage == nil,"Confirmed login clears transient QR")
  try store.save(endpoint:"https://other.example.org/mcp",token:"other-fixture-key")
  expect(!flow.isCurrent(reply.card!),"Connection change invalidates previous card references")
  try store.disconnect(); expect(!store.configured && store.qrImage == nil,"Disconnect clears local credential and transient auth material")
  let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n\n".utf8)
  expect(try XiaohongshuMCPClient.decode(sse)["id"] as? Int == 2,"MCP SSE response supported")
  let localDefaults = UserDefaults(suiteName:"xhs-local-test-"+UUID().uuidString)!
  let localStore = XiaohongshuMCPStore(defaults:localDefaults, factory: { _,_ in fatalError("Local mode must never use remote transport") })
  var localCalls: [XiaohongshuMCPClient.Tool] = [], stopped = 0
  let local = XiaohongshuLocalMCP { tool, args in
   localCalls.append(tool)
   switch tool {
   case .status: return ["content":[["type":"text","text":"✅ 已登录\n"]]]
   case .search: return ["structuredContent":["feeds":[["modelType":"note","id":backend.id,"xsecToken":"LOCAL-ACCESS-REF","noteCard":["displayTitle":"手机网页笔记","user":["nickname":"本机示例作者"]]]]]]
   case .detail: return ["structuredContent":["feed_id":backend.id,"data":["note":["noteId":backend.id,"title":"手机网页笔记","desc":"本机读取的正文","user":["nickname":"本机示例作者"]],"comments":["list":[]]]]]
   case .qr: fatalError("Local host never calls QR tool")
   }
  }
  localStore.installLocal(call: { tool,args in try await local.call(tool, arguments:args) }, stop:{ stopped += 1 })
  expect(localStore.mode == .local && localStore.configured && !localStore.ready,"Fresh connection defaults to phone mode without key/server")
  let localFlow = XiaohongshuMCPConversation(store:localStore)
  let localSearch = try await localFlow.run(.init(action:.search,keyword:"咖啡"),conversationID:UUID())
  expect(localCalls == [.status,.search] && localStore.ready,"Phone query checks login and calls local MCP without HTTP")
  expect(localSearch.card?.notes.first?.title == "手机网页笔记","Same production conversation cards accept local page evidence")
  let localDetail = try await localFlow.select(localSearch.card!,query:.init(action:.comments,noteID:backend.id))
  expect(localDetail.card?.coverage.contains("本机仅读取网页实际加载") == true,"Local comments explicitly describe loaded scope")
  localStore.selectMode(.remote)
  expect(stopped == 1 && !localStore.ready && !localFlow.isCurrent(localDetail.card!),"Changing backend stops phone host and revokes card authority")
  localStore.selectMode(.local)
  expect(!localStore.ready,"Switching back requires current account verification")
  localStore.invalidateLocalSession(); expect(!localStore.ready,"Local session change revokes account readiness")
  let rpc = XiaohongshuLocalMCP { _,_ in fatalError("Invalid RPC must not execute handler") }
  do { _ = try await rpc.handle(["jsonrpc":"2.0","method":"notifications/initialized"]); fatalError("Out of order handshake") } catch { count += 1 }
  _ = try await rpc.handle(["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-03-26"]])
  _ = try await rpc.handle(["jsonrpc":"2.0","method":"notifications/initialized"])
  let tools = try await rpc.handle(["jsonrpc":"2.0","id":2,"method":"tools/list"])
  let names = ((tools?["result"] as? [String:Any])?["tools"] as? [[String:Any]])?.compactMap { $0["name"] as? String } ?? []
  expect(Set(names) == Set(["check_login_status","search_feeds","get_feed_detail"]),"Phone MCP advertises only implemented read tools")
  for params: [String:Any] in [["name":"publish_content","arguments":[:]], ["name":"search_feeds","arguments":["keyword":"x","cookies":"override"]], ["name":"get_feed_detail","arguments":["feed_id":backend.id,"xsec_token":"ref","limit":1000]], ["name":"get_login_qrcode","arguments":[:]]] {
   do { _ = try await rpc.handle(["jsonrpc":"2.0","id":3,"method":"tools/call","params":params]); fatalError("Unsafe local RPC accepted") } catch { count += 1 }
  }
  print("PASS: \(count) Xiaohongshu production MCP transport, login, bounded read, ref ownership, privacy and failure checks; synthetic transport only")
 }
}
