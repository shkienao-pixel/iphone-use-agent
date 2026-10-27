import Foundation

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    if condition() { print("PASS \(description)") }
    else { print("FAIL \(description)"); failures += 1 }
}

let fake = "https://www.ctrip.com/not-a-real-train-page?trainNo=G2189&date=2026-10-29&fromStation=%E9%87%91%E5%B1%B1%E5%8C%97&toStation=%E6%9D%AD%E5%B7%9E%E4%B8%9C"
let cases = [
    ("unverified path with matching parameters", fake),
    ("conflicting date", fake.replacingOccurrences(of: "2026-10-29", with: "2026-10-28")),
    ("duplicate train parameter", fake + "&trainNo=G2189"),
    ("missing provider link", ""),
]
for (description, link) in cases {
    let response = """
    ### G2189
    - 出发站：金山北
    - 到达站：杭州东
    - 出发日期：2026-10-29
    - 出发时间：07:48
    - 详情链接：\(link)
    """
    let offers = CtripGroundTravelParser.offers(text: response, mode: .train)
    check(offers.count == 1 && offers[0].number == "G2189", "\(description): source remains visible")
    check(offers.first?.verifiedURL == nil, "\(description): no unsupported specific handoff")
}

let fixture = URL(fileURLWithPath: "Tests/AssistantConversation/Fixtures/UnifiedArchive/ctrip-train224.json")
let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
let messages = object["messages"] as! [[String: Any]]
let text = messages.first { $0["role"] as? String == "assistant" }!["text"] as! String
let actual = CtripGroundTravelParser.offers(text: text, mode: .train)
check(actual.count == 10, "saved live result still produces ten train cards")
check(actual.allSatisfy { $0.departureStation == "金山北站" || $0.departureStation == "上海松江站" }, "do not replace actual departure stations with the requested station")
check(actual.allSatisfy { $0.verifiedURL == nil }, "saved live results use the ordinary search action")
check(!actual.contains { $0.number == "G219" }, "public timetable references do not become live ticket cards")

let compactPrefix = """
来源：携程官方查询
以下车次信息均来自携程火车票实时查询结果，日期为2026年10月29日，到达站均为杭州东站。
### 金山北站出发车次
"""
func compact(_ suffix: String) -> [CtripGroundTravelOffer] {
    CtripGroundTravelParser.offers(text: compactPrefix + "\n- G2189：07:48出发 → 08:27到达，" + suffix, mode: .train)
}
for phrase in ["不支持候补", "暂不支持候补", "无法候补"] {
    let offers = compact("二等座52元，余票21张，" + phrase)
    check(offers.count == 1 && offers[0].availability.contains(phrase), "preserve waitlist restriction: \(phrase)")
    check(offers.first?.availability != "21张，支持候补", "never invert waitlist restriction: \(phrase)")
}
check(compact("二等座52元，余票21张，支持候补").first?.availability == "21张，支持候补", "explicit positive waitlist stays positive")
check(compact("二等座52元起，余票21张").first?.price == "52元起", "minimum fare retains its qualifier")
check(compact("二等座52元以上，余票21张").first?.price == "52元以上", "fare range retains its qualifier")
check(compact("二等座52元左右，余票21张").first?.price == "52元左右", "approximate fare retains its qualifier")
check(compact("二等座52元/人，余票21张").first?.price == "52元/人", "fare retains its unit")
check(compact("二等座52元 起，余票21张").first?.price == "52元 起", "spaced minimum fare retains its qualifier")
check(compact("二等座52元 左右，余票21张").first?.price == "52元 左右", "spaced approximate fare retains its qualifier")
for phrase in ["52元起售", "52元至80元", "52元~80元", "52元不含服务费", "52元 至80元", "52元 起售", "52元 ~ 80元"] {
    check(compact("二等座" + phrase + "，余票21张").first?.price == "", "unhandled fare qualifier or range remains unknown: \(phrase)")
}
check(compact("二等座52元，余票21张，金山北→杭州西").isEmpty, "reject conflicting route at end of row")
check(compact("二等座52元，余票21张，金山北→杭州东").count == 1, "accept matching route at end of row")
print("\(failures) failed")
if failures > 0 { exit(1) }
