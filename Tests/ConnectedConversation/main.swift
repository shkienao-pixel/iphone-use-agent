import Foundation
struct AgentSettings { var endpoint = "https://api.openai.com/v1/chat/completions"; var model = "gpt-6.1-sol"; var responseTokenLimit = 2048 }
struct AssistantMessage { let role: String; let text: String }
enum PrivacyConsent { static func allowed(_ settings: AgentSettings) -> Bool { true } }
enum ModelEndpointPolicy { static func url(_ value: String) throws -> URL { guard let url = URL(string: value), url.scheme == "https" else { throw AgentError.message("invalid") }; return url } }
enum AgentError: Error { case message(String) }
@main struct Checks {
 static func main() async throws {
  var checks = 0
  func expect(_ value: @autoclosure () -> Bool) { precondition(value()); checks += 1 }
  let settings = AgentSettings(), key = "offline-test-credential"
  let client = ConnectedConversationClient(settings: settings, apiKey: key)
  let req = try client.request(question: "今天的 AI 新闻", history: [.init(role:"user",text:"你好")], memoryContext: "historical data")
  let body = try JSONSerialization.jsonObject(with:req.httpBody!) as! [String:Any]
  expect(req.url!.absoluteString == "https://api.openai.com/v1/responses")
  expect(body["model"] as? String == settings.model)
  expect(body["store"] as? Bool == false)
  expect((body["tools"] as! [[String:String]])[0]["type"] == "web_search")
  expect((body["instructions"] as! String).contains("Current local date"))
  expect((body["input"] as! [[String:Any]]).count == 2)
  let fixture: [String:Any] = ["status":"completed","model":"actual-returned-model","output":[["type":"web_search_call"],["type":"message","role":"assistant","content":[["type":"output_text","text":"**已核实**","annotations":[["type":"url_citation","url":"https://example.org/news","title":"来源"],["type":"url_citation","url":"javascript:alert(1)","title":"bad"]]]]]]]
  let bytes = try JSONSerialization.data(withJSONObject:fixture)
  let reply = try ConnectedConversationClient.decode(bytes)
  expect(reply.model == "actual-returned-model"); expect(reply.searched)
  expect(reply.text.contains("https://example.org/news"));expect(!reply.text.contains("javascript:"))
  var incomplete = fixture; incomplete["status"] = "incomplete"
  do { _ = try ConnectedConversationClient.decode(JSONSerialization.data(withJSONObject:incomplete));preconditionFailure() } catch { checks += 1 }
  var custom = settings;custom.endpoint = "https://custom.invalid/v1/chat/completions"
  expect(!ConnectedConversationClient.supports(custom))
  func failure(_ status: Int, _ code: String, _ type: String = "", _ param: String = "") throws -> String {
   ConnectedConversationClient.failureMessage(status:status,data:try JSONSerialization.data(withJSONObject:["error":["code":code,"type":type,"param":param,"message":"DO_NOT_SHOW_"+key]]))
  }
  let quota=try failure(429,"insufficient_quota")
  expect(quota.contains("额度不足") && !quota.contains("限速"))
  let rate=try failure(429,"rate_limit_exceeded")
  expect(rate.contains("限速") && !rate.contains("额度不足"))
  expect((try? failure(401,"invalid_api_key"))?.contains("身份验证") == true)
  expect((try? failure(404,"model_not_found"))?.contains("模型不可用") == true)
  expect((try? failure(400,"unsupported_parameter","","max_output_tokens"))?.contains("回复长度") == true)
  expect((try? failure(400,"invalid_json_schema"))?.contains("结构化回复格式") == true)
  for status in [400,401,403,429,500] {
   let message=try failure(status,key,key,key)
   expect(message.contains("HTTP \(status)") && !message.contains(key) && !message.contains("DO_NOT_SHOW"))
  }
  expect(ConnectedConversationClient.failureMessage(status:429,data:Data("invalid JSON".utf8)).contains("请求未完成"))
  let travel = MeituanTravelClient(token:key)
  let travelReq = try travel.request(query:"上海酒店，仅查询")
  let travelBody = try JSONSerialization.jsonObject(with:travelReq.httpBody!) as! [String:String]
  expect(travelReq.url == MeituanTravelClient.endpoint)
  expect(travelReq.value(forHTTPHeaderField:"Authorization") == key)
  expect(travelBody["originQuery"] == "上海酒店，仅查询")
  expect(travelBody["channel"] == "meituan-developer")
  var injected = travel
  injected.transport = { req in (try JSONSerialization.data(withJSONObject:["code":0,"data":"真实旅行参考，未预订"]),HTTPURLResponse(url:req.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
  let result = try await injected.query("上海酒店")
  expect(result.contains("未预订"))
  injected.transport = { req in (try JSONSerialization.data(withJSONObject:["code":0,"data":"leaked " + key]),HTTPURLResponse(url:req.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
  do { _ = try await injected.query("上海酒店");preconditionFailure() } catch { checks += 1 }
  let tool = try SystemToolRequest.decode(#"{"operation":"meituan_query","query":"上海周末酒店，只查价格"}"#)
  expect(tool.operation == .meituan_query);expect(!tool.operation.writes)
  do { _ = try SystemToolRequest.decode(#"{"operation":"meituan_query","query":"上海酒店","title":"unexpected"}"#);preconditionFailure() } catch {checks += 1}
  print("\(checks) connected chat and Meituan contract checks passed; offline transport only")
 }
}
