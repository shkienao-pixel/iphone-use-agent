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

let summaryText = try String(contentsOfFile: "Tests/CtripGroundTravel/Fixtures/build240-live-train-summary.txt", encoding: .utf8)
func summary(_ text: String) -> [CtripGroundTravelOffer] {
    CtripGroundTravelParser.offers(text: text, mode: .train)
}
let liveSummary = summary(summaryText)
check(liveSummary.count == 1 && liveSummary.first?.number == "G7541", "live Build 240 summary renders only the explicit direct train")
check(liveSummary.first?.departureStation == "上海虹桥" && liveSummary.first?.arrivalStation == "杭州东", "summary uses its actual stations without substituting query values")
check(liveSummary.first?.departureDate == "2026-10-29" && liveSummary.first?.departureTime == "05:52" && liveSummary.first?.arrivalTime == "06:51", "summary date and times bind to the same train")
check(liveSummary.first?.seat == "二等座" && liveSummary.first?.price == "¥57.0" && liveSummary.first?.availability == "余21张", "summary preserves one seat's fare and remaining tickets")
check(liveSummary.first?.arrivalDate == "", "summary does not invent a calendar arrival date")
check(liveSummary.allSatisfy { $0.verifiedURL == nil }, "summary never fabricates a specific train handoff")
check(!liveSummary.contains { ["G7331", "G1381", "G3091"].contains($0.number) }, "transfer legs and different-station alternatives do not become direct cards")
let row = "- 10月29日 周四 05:52 上海虹桥 → 06:51 杭州东"
for (description, changed) in [
    ("conflicting destination", summaryText.replacingOccurrences(of: row, with: row.replacingOccurrences(of: "杭州东", with: "杭州西"))),
    ("conflicting origin", summaryText.replacingOccurrences(of: row, with: row.replacingOccurrences(of: "上海虹桥", with: "上海松江"))),
    ("conflicting month and day", summaryText.replacingOccurrences(of: row, with: row.replacingOccurrences(of: "10月29日", with: "10月30日"))),
    ("conflicting departure", summaryText.replacingOccurrences(of: row, with: row.replacingOccurrences(of: "05:52", with: "05:53"))),
    ("different train in nested summary", summaryText.replacingOccurrences(of: "##### · G7541", with: "##### · G7542")),
    ("duplicate itinerary summary", summaryText.replacingOccurrences(of: row, with: row + "\n" + row)),
    ("multiple train numbers in heading", summaryText.replacingOccurrences(of: "### G7541（", with: "### G7541-G7542（")),
    ("transfer heading", summaryText.replacingOccurrences(of: "### G7541（强烈推荐 · 有票）", with: "### G7541（中转方案）")),
    ("transfer and second train inside heading parentheses", summaryText.replacingOccurrences(of: "### G7541（强烈推荐 · 有票）", with: "### G7541（换乘 G7542）")),
    ("second train inside heading parentheses", summaryText.replacingOccurrences(of: "### G7541（强烈推荐 · 有票）", with: "### G7541（后续 G7542）")),
    ("transfer inside direct section", summaryText.replacingOccurrences(of: row, with: row + "\n- 第2段：G7542，中转去杭州东")),
    ("missing explicit result year", summaryText.replacingOccurrences(of: "以下为2026年10月29日", with: "以下为10月29日")),
    ("missing official source", summaryText.replacingOccurrences(of: "携程官方查询", with: "网络参考")),
    ("non-direct section", summaryText.replacingOccurrences(of: "## 直达车次（", with: "## 中转车次（")),
] {
    check(summary(changed).isEmpty, "summary rejects \(description)")
}
for conflictingField in ["到达站：杭州西", "出发站：上海松江", "乘车日期：2026-10-30", "车次：G7542", "发车时间：05:53", "到达时间：06:52", "发车时间：05:52 或 06:00", "到达时间：06:51至07:00", "乘车日期：2026-10-29至10-30"] {
    check(summary(summaryText.replacingOccurrences(of: row, with: row + "\n- " + conflictingField)).isEmpty, "summary rejects explicit conflicting field \(conflictingField)")
}
check(summary(summaryText.replacingOccurrences(of: row, with: row + "\n- 到达站：杭州东站\n- 乘车日期：2026-10-29")).count == 1, "matching explicit fields agree with the summary")
let conflictingCompleteFields = "- 出发站：上海虹桥\n- 到达站：杭州西\n- 出发日期：2026-10-29\n- 出发时间：05:52\n"
check(summary(summaryText.replacingOccurrences(of: "##### · G7541", with: conflictingCompleteFields + "##### · G7541")).isEmpty, "complete conflicting field block cannot bypass summary rejection")
check(summary(summaryText.replacingOccurrences(of: "05:52 → 06:51", with: "05:52 上海松江 → 06:51 杭州东")).isEmpty, "unsupported labeled timing with conflicting station is rejected")
let directStart = summaryText.range(of: "### G7541")!.lowerBound
let directEnd = summaryText.range(of: "## 中转/非杭州东")!.lowerBound
let directBlock = String(summaryText[directStart..<directEnd])
let duplicated = summaryText.replacingOccurrences(of: directBlock, with: directBlock + directBlock)
check(summary(duplicated).count == 1, "repeated identical train blocks produce one card")
let conflictingDuplicate = summaryText.replacingOccurrences(of: directBlock, with: directBlock + directBlock.replacingOccurrences(of: "05:52", with: "05:53"))
check(summary(conflictingDuplicate).isEmpty, "same train identity with contradictory timetable is rejected")
let fareRow = "- **二等座**：¥57.0，余21张"
check(summary(summaryText.replacingOccurrences(of: fareRow, with: "")).first?.price == "", "missing summary fare remains unknown")
check(summary(summaryText.replacingOccurrences(of: fareRow, with: "- **二等座**：¥0，余0张")).first?.price == "¥0", "explicit zero fare is preserved")
check(summary(summaryText.replacingOccurrences(of: fareRow, with: "- **二等座**：¥57.0起，余21张")).first?.price == "¥57.0起", "summary minimum fare keeps its qualifier")
check(summary(summaryText.replacingOccurrences(of: fareRow, with: "- **二等座**：¥57.0至¥80，余21张")).first?.price == "", "unhandled summary fare range remains unknown")
let twoSeats = summary(summaryText.replacingOccurrences(of: fareRow, with: fareRow + "\n- 一等座：¥91.0，余10张"))
check(twoSeats.count == 2 && twoSeats.map(\.seat) == ["二等座", "一等座"] && twoSeats.map(\.price) == ["¥57.0", "¥91.0"] && twoSeats.map(\.availability) == ["余21张", "余10张"], "same train summary keeps each seat's own fare and inventory")
check(summary(summaryText.replacingOccurrences(of: fareRow, with: fareRow + "\n- 二等座：¥57.0至¥80，余票待查")).isEmpty, "an additional unparsed quote cannot validate a conflicting quote for the same seat")
check(summary(summaryText.replacingOccurrences(of: fareRow, with: fareRow + "\n" + fareRow)).count == 1, "identical repeated seat quotes are deduplicated")
let mixedSeatConflict = summary(summaryText.replacingOccurrences(of: fareRow, with: fareRow + "\n- 一等座：¥91.0，余10张\n- 二等座：¥58.0，余21张"))
check(mixedSeatConflict.count == 1 && mixedSeatConflict.first?.seat == "一等座", "conflicting same-seat fare is rejected without losing a different consistent seat")
let duplicateSeatBlocks = summaryText.replacingOccurrences(of: directBlock, with: directBlock + directBlock.replacingOccurrences(of: fareRow, with: "- 一等座：¥91.0，余10张"))
check(summary(duplicateSeatBlocks).count == 2, "same train in separate summary blocks preserves different seats")
let conflictingSeatTimetable = summaryText.replacingOccurrences(of: directBlock, with: directBlock + directBlock.replacingOccurrences(of: fareRow, with: "- 一等座：¥91.0，余10张").replacingOccurrences(of: "05:52", with: "05:53"))
check(summary(conflictingSeatTimetable).isEmpty, "different summary seats cannot bypass contradictory train timetables")
check(summary(summaryText.replacingOccurrences(of: fareRow, with: "- **二等座**：¥57.0，无票，不支持候补")).first?.availability == "无票，不支持候补", "summary preserves sold-out and negative waitlist qualifiers")

let seatTableHeader = """
|车次|出发站|到达站|出发日期|出发时间|到达日期|到达时间|席别|票价|余票|
|---|---|---|---|---|---|---|---|---|---|
"""
let secondClass = "|G100|上海虹桥|杭州东|2026-10-29|08:00|2026-10-29|09:00|二等座|50元|有票|"
let firstClass = "|G100|上海虹桥|杭州东|2026-10-29|08:00|2026-10-29|09:00|一等座|80元|余5张|"
func trainTable(_ rows: [String]) -> [CtripGroundTravelOffer] { summary(seatTableHeader + "\n" + rows.joined(separator: "\n")) }
let tableSeats = trainTable([secondClass, firstClass])
check(tableSeats.count == 2 && tableSeats.map(\.seat) == ["二等座", "一等座"] && tableSeats.map(\.price) == ["50元", "80元"] && tableSeats.map(\.availability) == ["有票", "余5张"], "table keeps distinct seats on one train with no mixed fare or inventory")
check(Set(tableSeats.map(\.id)).count == 2 && tableSeats.allSatisfy { $0.verifiedURL == nil }, "seat cards have distinct IDs and no invented booking links")
check(trainTable([secondClass, firstClass, secondClass, firstClass]).count == 2, "identical table quotes deduplicate only within their seat")
for changed in [secondClass.replacingOccurrences(of: "50元", with: "51元"), secondClass.replacingOccurrences(of: "有票", with: "无票")] {
    let conflict = trainTable([secondClass, firstClass, changed])
    check(conflict.count == 1 && conflict.first?.seat == "一等座", "contradictory fare or inventory rejects that seat while preserving independent alternatives")
    check(trainTable([secondClass, changed]).isEmpty, "same-seat conflict cannot select an arbitrary row")
}
for changed in [firstClass.replacingOccurrences(of: "08:00", with: "08:01"), firstClass.replacingOccurrences(of: "09:00", with: "09:01"), firstClass.replacingOccurrences(of: "|2026-10-29|09:00", with: "|2026-10-30|09:00")] {
    check(trainTable([secondClass, changed]).isEmpty, "different seats cannot bypass conflicting train departure or arrival evidence")
}
check(CtripGroundTravelParser.displayEntries(text: seatTableHeader + "\n" + secondClass + "\n" + firstClass, mode: .train).map(\.seat) == ["二等座", "一等座"], "production display entry path retains all valid seat options")

let busText = try String(contentsOfFile: "Tests/CtripGroundTravel/Fixtures/build240-live-bus-city-only.txt", encoding: .utf8)
check(CtripGroundTravelParser.offers(text: busText, mode: .bus).isEmpty, "live bus response with cities only does not invent specific coach stations")
check(CtripGroundTravelParser.offers(text: summaryText, mode: .bus).isEmpty, "train summary format never becomes bus cards")
let namedBus = """
## 汽车班次
- 出发站：上海长途汽车客运总站
- 到达站：苏州汽车北站
- 发车日期：2026-10-29
- 发车时间：09:00
- 票价：80元
"""
let buses = CtripGroundTravelParser.offers(text: namedBus, mode: .bus)
check(buses.count == 1 && buses.first?.departureStation == "上海长途汽车客运总站" && buses.first?.arrivalStation == "苏州汽车北站", "explicit coach station fields retain existing cards")
check(buses.first?.verifiedURL == nil, "explicit coach result still uses general provider search")

// The real Build 240/243 coach response retained in the fixture is exactly
// the screenshot regression: five source rows with cities but no terminals.
func display(_ text: String, mode: CtripGroundTravelMode = .bus) -> [CtripGroundTravelDisplayEntry] {
    CtripGroundTravelParser.displayEntries(text: text, mode: mode)
}
let coachDisplay = display(busText)
check(coachDisplay.count == 5, "real city-only source produces five read-only result cards")
check(coachDisplay.allSatisfy { !$0.isComplete && $0.departureStation.isEmpty && $0.arrivalStation.isEmpty }, "city-only cards never claim known coach terminals or complete departures")
check(coachDisplay.allSatisfy { $0.departureCity == "上海市" && $0.arrivalCity == "苏州市" && $0.departureDate == "2026-10-29" }, "city and date facts remain scoped to their own source records")
check(coachDisplay.map(\.departureTime) == ["00:30", "00:30", "00:45", "00:45", "01:00"], "duplicate departure times retain separate source rows")
check(coachDisplay.map(\.price) == ["160元/人", "180元/人", "140元/人", "120元/人", "180元/人"], "same-time rows retain distinct unmodified fares")
check(coachDisplay.map(\.availability) == ["97张", "97张", "99张", "99张", "95张"], "source inventories bind to the correct fare rows")
check(coachDisplay.allSatisfy { $0.serviceFee == "3元" && $0.verifiedURL == nil && $0.number.isEmpty }, "fees remain visible and ordinal titles never become real identifiers or links")
check(coachDisplay.first?.duration == "约2小时40分" && coachDisplay[2].duration == "约2小时0分", "duration qualifiers survive presentation")
check(display(busText.replacingOccurrences(of: "## ", with: "")).count == 5, "plain coach titles delimit all five source records")
check(display(busText.replacingOccurrences(of: "## ", with: "**").replacingOccurrences(of: "出发）", with: "出发）**")).count == 5, "bold coach titles delimit all five source records")
check(display(busText.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "：", with: ":")).count == 5, "unmarked English-colon fields remain parseable")
let archived = try JSONEncoder().encode(["text": busText, "groundQuery": "汽车票查询", "groundTravelMode": "bus"])
let restored = try JSONDecoder().decode([String: String].self, from: archived)
check(display(restored["text"]!) == coachDisplay, "saved response JSON round-trip restores identical cards without a new query")
check(display(busText) == coachDisplay, "repeated presentation keeps card IDs and facts stable")
check(display(summaryText).isEmpty, "coach display cannot reinterpret a train summary")
check(display(summaryText, mode: .train).count == 1, "train display retains one verified direct summary")
check(display(conflictingDuplicate, mode: .train).isEmpty, "train display cannot bypass duplicate-summary conflict rejection")
check(display(summaryText.replacingOccurrences(of: row, with: row + "\n- 第2段：G7542，中转去杭州东"), mode: .train).isEmpty, "train presentation cannot revive transfer summaries through a fallback")

let firstBus = String(busText[..<busText.range(of: "## 班次二")!.lowerBound])
let completeBus = namedBus + "\n- 班次号：S001\n- 出发城市：上海市\n- 到达城市：苏州市"
check(display(completeBus).first?.isComplete == true, "explicit coach terminals and date/time retain a complete read-only entry")
check(display(completeBus + "\n" + firstBus).count == 2 && display(completeBus + "\n" + firstBus).map(\.isComplete) == [true, false], "complete record does not discard a following incomplete record")
let cityStation = namedBus.replacingOccurrences(of: "上海长途汽车客运总站", with: "上海市").replacingOccurrences(of: "苏州汽车北站", with: "苏州市")
check(CtripGroundTravelParser.offers(text: cityStation, mode: .bus).isEmpty, "explicit station labels containing cities are still not complete offers")
check(display(cityStation).first?.departureStation == "" && display(cityStation).first?.departureCity == "上海市" && display(cityStation).first?.isComplete == false, "city under a station label is visibly incomplete instead of mislabelled as a terminal")
check(display(firstBus + "\n- 实际出发客运站：上海长途汽车客运总站\n- 实际到达客运站：苏州汽车北站").first?.isComplete == true, "independently stated cities coexist with actual station facts")

let tableText = try String(contentsOfFile: "Tests/CtripGroundTravel/Fixtures/coach-display-table.txt", encoding: .utf8)
let tableDisplay = display(tableText)
check(tableDisplay.count == 3 && tableDisplay.map(\.isComplete) == [false, true, false], "mixed partial and complete table rows are all displayed")
check(tableDisplay.map(\.price) == ["160元/人", "80元", "180元/人"], "table row fares preserve distinct same-time records")
check(tableDisplay.first?.departureCity == "上海市" && tableDisplay.first?.departureStation == "", "table city route remains distinct from station fields")
check(display(completeBus + "\n" + tableText + "\n" + firstBus).count == 5, "one response can mix complete blocks, partial tables and partial blocks")
check(display(tableText.replacingOccurrences(of: "| ", with: "|").replacingOccurrences(of: " |", with: "|")).count == 3, "table parsing tolerates whitespace changes")
let conflictTable = """
| 出发站 | 到达站 | 发车日期 | 发车时间 | 票价 | 票价 | 票价 |
| --- | --- | --- | --- | --- | --- | --- |
| 上海长途汽车客运总站 | 苏州汽车北站 | 2026-10-29 | 09:00 | 80元 | 90元 | 80元 |
"""
check(display(conflictTable).first?.price == "", "table field conflict cannot be undone by a third matching value")
check(CtripGroundTravelParser.offers(text: conflictTable, mode: .bus).first?.price == "", "complete offers also retain sticky table fare conflicts")
let stationConflictTable = conflictTable.replacingOccurrences(of: "票价 | 票价 | 票价", with: "出发站 | 出发站 | 出发站").replacingOccurrences(of: "80元 | 90元 | 80元", with: "上海长途汽车客运总站 | 上海客运南站 | 上海长途汽车客运总站")
check(display(stationConflictTable).first?.departureStation == "" && display(stationConflictTable).first?.isComplete == false, "table station conflict preserves the row but makes the station unknown")
check(CtripGroundTravelParser.offers(text: stationConflictTable, mode: .bus).isEmpty, "table station conflict never resurrects a complete offer")

let fieldsToConflict: [(String, String, String, KeyPath<CtripGroundTravelDisplayEntry, String>)] = [
    ("出发站", "上海长途汽车客运总站", "上海客运南站", \.departureStation),
    ("到达站", "苏州汽车北站", "苏州汽车南站", \.arrivalStation),
    ("出发城市", "上海市", "南京市", \.departureCity),
    ("到达城市", "苏州市", "杭州市", \.arrivalCity),
    ("发车日期", "2026-10-29", "2026-10-30", \.departureDate),
    ("发车时间", "09:00", "09:30", \.departureTime),
    ("到达日期", "2026-10-29", "2026-10-30", \.arrivalDate),
    ("到达时间", "11:00", "11:30", \.arrivalTime),
    ("席别", "普通座", "商务座", \.seat),
    ("票价", "80元", "90元", \.price),
    ("余票", "97张", "98张", \.availability),
    ("历时", "约2小时", "约3小时", \.duration),
    ("在线服务费", "3元", "5元", \.serviceFee)
]
for (label, initial, differing, key) in fieldsToConflict {
    let changed = completeBus + "\n- " + label + "：" + initial + "\n- " + label + "：" + differing + "\n- " + label + "：" + initial
    let entries = display(changed)
    check(entries.count == 1 && entries.first?[keyPath: key] == "", "conflicting \(label) remains unknown after later repetition")
}
let numberedBlocks = """
班次：A
出发站：上海长途汽车客运总站
发车日期：2026-10-29
发车时间：09:00

班次：B
到达站：苏州汽车北站
票价：80元
"""
check(display(numberedBlocks).count == 2 && display(numberedBlocks).allSatisfy { !$0.isComplete }, "explicit new coach numbers split unmarked partial source records")
check(display(numberedBlocks).map(\.number) == ["A", "B"] && display(numberedBlocks)[0].arrivalStation.isEmpty && display(numberedBlocks)[1].departureStation.isEmpty, "new number cannot combine one record's origin with another record's destination")
check(CtripGroundTravelParser.offers(text: numberedBlocks, mode: .bus).isEmpty, "complete offer path uses the same explicit-number boundaries")
let sameNumberConflict = completeBus + "\n- 班次号：S001\n- 票价：90元\n- 班次号：S001\n- 票价：80元"
check(display(sameNumberConflict).count == 1 && display(sameNumberConflict).first?.price == "", "repeated same number does not reset a conflicting fare")
check(display(completeBus.replacingOccurrences(of: "上海长途汽车客运总站", with: "不是上海长途汽车客运总站")).first?.isComplete == false, "negated terminal name cannot identify a complete departure")
check(CtripGroundTravelParser.offers(text: completeBus.replacingOccurrences(of: "上海长途汽车客运总站", with: "不是上海长途汽车客运总站"), mode: .bus).isEmpty, "negative station wording cannot become a genuine station offer")
check(display(namedBus.replacingOccurrences(of: "票价：80元", with: "参考票价：80元")).first?.price == "参考80元", "reference-price label retains its qualifier in display data")
check(CtripGroundTravelParser.offers(text: namedBus.replacingOccurrences(of: "票价：80元", with: "参考票价：80元"), mode: .bus).first?.price == "参考80元", "reference-price qualifier also survives complete offer parsing")
let headingConflict = firstBus + "\n- 发车时间：00:45\n- 发车时间：00:30"
check(display(headingConflict).first?.departureTime == "" && display(headingConflict).first?.price == "160元/人", "heading/time conflict preserves independent known fields")
let ambiguousClock = firstBus + "\n- 发车时间：00:30 或 00:45\n- 发车时间：00:30"
check(display(ambiguousClock).first?.departureTime == "", "multiple clocks never select the first clock or recover via repetition")
let ambiguousDate = firstBus + "\n- 发车日期：2026-10-29至2026-10-30\n- 发车日期：2026-10-29"
check(display(ambiguousDate).first?.departureDate == "", "a conflicting date range remains unknown")
let malformedRoute = firstBus + "\n- 出发/到达：上海市→苏州市→杭州市\n- 出发/到达：上海市→苏州市"
check(display(malformedRoute).first?.departureCity == "" && display(malformedRoute).first?.arrivalCity == "", "ambiguous route poisons endpoint fields without losing price evidence")
check(display(firstBus.replacingOccurrences(of: "160元/人", with: "0元/人").replacingOccurrences(of: "97张", with: "0张")).first?.price == "0元/人", "explicit zero remains distinguishable from unknown")
for explanation in ["暂无查询结果", "未查询到汽车班次", "没有实际查询结果", "以下数据来自公开时刻表", "网络参考，非实时结果", "以下为示例数据"] {
    let response = "来源：携程官方查询\n" + explanation + "\n" + completeBus
    check(CtripGroundTravelParser.offers(text: response, mode: .bus).isEmpty && display(response).isEmpty, "negative/reference response cannot become real offers or result rows: \(explanation)")
}
for emptyText in ["", "请求暂时失败，请稍后重试", "暂无汽车票结果", "只有一段不可识别的正文", "## 汽车班次\n票价：80元", "## 班次一"] {
    check(display(emptyText).isEmpty, "empty/unrecognized response leaves the result container to UI: \(emptyText)")
}
check(display(String(repeating: "车", count: 50_000)).isEmpty, "oversized results stay unparsed")

print("\(failures) failed")
if failures > 0 { exit(1) }
