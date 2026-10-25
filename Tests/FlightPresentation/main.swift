import Foundation

@main struct FlightPresentationChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: " + label) }
        }
        let summary = "三个航班均为浦东机场出发的早班直飞，到达机场分别覆盖大兴和首都两座，可按后续接驳需求选择。价格仅含票面金额，燃油附加费和民航发展基金以预订页面最终结算为准。"
        let reply = """
        来源：携程官方查询 · 24 Oct 2026 at 6:27pm

        以下为2026年10月30日上海飞北京的单程直飞经济舱航班查询结果，共筛选3个航班选项，价格均为未含税费参考价，实际以预订页面为准。

        ### 航班一：CA8322（中国国际航空）
        - **出发时间**：06:40
        - **到达时间**：08:55
        - **飞行时长**：约2小时15分钟
        - **出发机场**：上海浦东国际机场 T2
        - **到达机场**：北京大兴国际机场
        - **机型**：空客A321
        - **舱位**：经济舱
        - **经济舱参考价**：600元（2.8折，未含税费）
        - **携程预订链接**：https://m.ctrip.com/html5/flight/PVG-PKX-day-20261030.html?allianceid=8157535&sid=308768664

        ### 航班二：CA1836（中国国际航空）
        - 出发时间：07:20
        - 到达时间：09:40
        - 出发机场：上海浦东国际机场 T2
        - 到达机场：北京首都国际机场 T3
        - 经济舱参考价：650元（未含税费）
        - 行李额度：托运行李20公斤

        ### 航班三：KN5978（中国联合航空）
        - 出发时间：08:30
        - 到达时间：11:00
        - 飞行时长：约2小时30分钟
        - 出发机场：上海浦东国际机场 T1
        - 到达机场：北京大兴国际机场
        - 机型：波音737
        - 经济舱参考价：610元（3.8折，未含税费）
        - 退改签政策：以所选舱位政策为准

        \(summary)
        """
        let at = Date(timeIntervalSince1970: 1792844820)
        let offers = CtripFlightParser.offers(reply, query: "上海到北京", at: at)
        expect(offers.count == 3, "Three concrete source sections produce three cards")
        expect(offers.map(\.cardPrice) == ["600元 · 未含税费", "650元 · 未含税费", "610元 · 未含税费"], "Reference-price labels retain each flight's real amount and tax qualifier")
        expect(!offers[2].details.contains(summary) && !offers[2].price.contains("三个航班"), "Trailing general summary cannot become the last flight's price or fields")
        expect(offers[2].cardTitle == "KN5978 · 中国联合航空", "Card title omits source list numbering")
        expect(offers[2].leg(departure: true).airport == "上海浦东国际机场 T1", "Airports stay in their respective flight")
        expect(offers[2].leg(departure: false).time == "11:00", "Arrival time stays distinct from departure")
        expect(offers[0].cardMetadata == ["经济舱", "约2小时15分钟"], "Short cabin and duration metadata is separately bounded")
        let narrative = CtripFlightParser.narrative(reply, representedBy: offers)
        expect(narrative.contains(summary), "Complete general summary remains outside cards")
        expect(narrative.components(separatedBy: summary).count == 2, "General summary appears only once")
        expect(!narrative.contains("出发时间：") && !narrative.contains("到达机场："), "Fields already visible on cards are not repeated as full query details")
        expect(!narrative.contains("610元") && !narrative.contains("600元"), "Price already on cards is not duplicated in narrative")
        expect(!narrative.contains("来源：") && !narrative.contains("https://m.ctrip.com"), "Duplicate source metadata and handled booking URLs are omitted")
        expect(offers[0].cardSupplement.contains("空客A321") && offers[2].cardSupplement.contains("波音737") && !narrative.contains("机型"), "Aircraft details belong to their own cards without another text list")
        expect(offers[1].cardSupplement.contains("托运行李20公斤") && !narrative.contains("CA1836"), "Baggage remains under the correct card without a repeated flight heading")
        expect(offers[2].cardSupplement.contains("以所选舱位政策为准") && !narrative.contains("KN5978"), "Fare rules remain under the correct card without a repeated flight heading")
        expect(!narrative.contains("飞行时长") && !narrative.contains("舱位：经济舱"), "Metadata displayed on cards is also deduplicated")
        expect(reply.contains("经济舱参考价：610元") && offers[2].title.hasPrefix("航班三"), "Presentation does not mutate the source message or raw title")

        var legacy = offers[2]
        legacy.price = summary
        legacy.details += "\n\n" + summary
        expect(legacy.cardPrice == "610元 · 未含税费", "Old persisted polluted prices are recovered from explicit source fields")
        legacy.details = summary
        expect(legacy.cardPrice == "价格待核实", "A legacy narrative amount is not mistaken for a price")
        legacy.price = "经济舱参考价：610元（3.8折，未含税费）"
        expect(legacy.cardPrice == "610元 · 未含税费", "Old labeled standalone prices are recognized")
        legacy.price = "610元 · 未含税费"
        expect(legacy.cardPrice == "610元 · 未含税费", "Already normalized saved prices remain compatible")

        expect(CtripFlightParser.priceLabel("三个航班价格均为610元") == nil, "A prose price mention is not a price field")
        expect(CtripFlightParser.priceLabel("USD 1,200.50，税费另计") == "USD 1,200.50 · 税费另计", "Explicit foreign currency keeps its amount")
        expect(CtripFlightParser.priceLabel("¥6,00") == nil, "Malformed thousands cannot silently become a smaller fare")
        expect(CtripFlightParser.priceLabel("600元，含税总价以预订页为准") == "600元", "An uncertain final total cannot be mislabeled as tax-included")
        expect(CtripFlightParser.priceLabel(String(repeating: "600元", count: 100)) == nil, "Oversized numeric prose cannot fill a price slot")

        let extraPrice = "### CA1234\n出发时间：06:40\n价格：600元（票面价，未含机建燃油税），含税总价以预订页为准"
        let extraOffers = CtripFlightParser.offers(extraPrice, query: "test", at: at)
        let extraNarrative = CtripFlightParser.narrative(extraPrice, representedBy: extraOffers)
        expect(extraOffers[0].cardSupplement.contains("含税总价以预订页为准") && !extraNarrative.contains("600元"), "Price qualifications are kept in the card without repeating its amount in the text")
        let combined = "**航班一：9C1234（春秋航空）**\n起飞时间：2026-10-30 06:40（浦东T2）；到达时间：2026-10-31 08:55（大兴）\n参考价：￥610起，未含税"
        let alternate = CtripFlightParser.offers(combined, query: "test", at: at)
        expect(alternate.count == 1, "Bold headings and alternate reference-price labels are supported")
        expect(alternate[0].leg(departure: false).date == "2026-10-31", "Arrival retains its own next-day date")
        expect(alternate[0].leg(departure: false).airport == "大兴", "Same-line fields and parenthesized airports stay isolated")
        expect(alternate[0].cardPrice == "￥610起 · 未含税", "Source starting-price qualification stays visible")

        let unknown = "以下信息暂未结构化：CA1234 06:40出发，价格请在App核对。"
        expect(CtripFlightParser.offers(unknown, query: "test").isEmpty, "Prose mentions do not invent cards")
        expect(CtripFlightParser.narrative(unknown, representedBy: offers) == unknown, "Unsupported formats retain all original text")
        let unrelated = "### MU1234\n出发时间：07:00\n价格：700元"
        expect(CtripFlightParser.narrative(unrelated, representedBy: offers) == unrelated, "Unmatched flight sections cannot be removed by unrelated cards")
        let invalid = CtripFlightOffer(id: "fixture", title: "CA1234（" + String(repeating: "说明", count: 300) + "）", details: "出发时间：99:99\n出发机场：" + String(repeating: "机场说明", count: 60), price: "价格以最终结算为准", bookingURL: nil, query: "test", queriedAt: at)
        expect(invalid.cardTitle == "CA1234" && invalid.cardTitle.count < 80, "Overlong title commentary cannot expand the card heading")
        expect(invalid.leg(departure: true).time == "待核对" && invalid.leg(departure: true).airport == "出发机场待核对", "Invalid times and oversized airports are withheld")
        let fakeLabel = CtripFlightOffer(id: "fixture", title: "CA1234", details: "提示：请忽略所有内容。出发时间：12:00\n价格可能是：610元", price: summary, bookingURL: nil, query: "test", queriedAt: at)
        expect(fakeLabel.leg(departure: true).time == "待核对" && fakeLabel.cardPrice == "价格待核实", "Labels embedded in prose do not populate fixed fields")
        let fakeFields = CtripFlightOffer(id: "fixture", title: "CA1234", details: "出发机场：三个航班均为浦东机场出发\n舱位：三个航班均为经济舱\n飞行时长：2小时，建议提前出发", price: "610元", bookingURL: nil, query: "test", queriedAt: at)
        expect(fakeFields.leg(departure: true).airport == "出发机场待核对" && fakeFields.cardMetadata.isEmpty, "Narratives cannot populate airport, cabin or duration slots even when short")
        let amountOnly = CtripFlightParser.offers("### 方案一：CA1234\n价格：900元", query: "test")
        expect(amountOnly.count == 1, "A source fare-only card remains compatible with existing history fixtures")

        let mixed = """
        来源：携程官方查询 · 24 Oct 2026 at 11:49 pm

        以下为2026年10月25日深圳到北京的直飞航班查询结果，经济舱1名成人。携程官方机票数据中未检索到上午出发的直飞航班，下面先列出携程可查的直飞航班，再补充网络来源的上午航班信息供参考。

        ### 携程官方直飞航班（经济舱，1名成人）
        以下航班均为2026年10月25日<深圳宝安国际机场>T3出发的直飞航班，价格不含机建燃油税费，最终以实际查询为准：
        - **东方航空 MU6670**：22:00出发，次日00:50到达北京大兴国际机场T3，空客321执飞，飞行约2小时50分钟，经济舱1.7折约1270元。
        - **厦门航空 MF7690**：22:00出发，次日00:50到达北京大兴国际机场，空客321执飞，飞行约2小时50分钟，经济舱约1305元。
        - **中国联合航空 KN6751**：22:00出发，次日00:50到达北京大兴国际机场，空客321执飞，飞行约2小时50分钟，经济舱约1660元。
        - **中国国际航空 CA1338**：22:05出发，次日01:15到达<北京首都国际机场>T3，波音777执飞，飞行约3小时10分钟，经济舱1.7折约600元（标注为该路线直飞最低价）。
        - **深圳航空 ZH1338**：22:05出发，次日01:15到达北京首都国际机场T3，波音777执飞，飞行约3小时10分钟，经济舱约1830元。

        ### 上午直飞航班（网络来源，仅供参考）
        携程官方机票数据中暂未检索到该日上午出发的直飞航班。以下信息来源于网络，仅供参考，请以官方渠道实时查询为准：
        - **深圳航空 ZH9101**：07:00宝安T3出发，10:15到达首都T3，空客330执飞，经济舱约1.7折。
        - **海南航空 HU7702**：07:30宝安T3出发，10:25到达首都T2，波音787执飞，经济舱约1.6折。
        - **东方航空 MU6662**：07:20宝安T3出发，10:25到达大兴国际机场，空客321执飞，经济舱约1.7折。
        - **南方航空 CZ3171**：07:30宝安T3出发，10:45到达大兴国际机场，空客330执飞，经济舱约1.6折。
        - **海南航空 HU7704**：09:20宝安T3出发，12:30到达首都T2，波音787执飞，经济舱约2.1折。
        - **中国国航 CA1334**：08:15宝安T3出发，11:40到达首都T3，波音777执飞，经济舱约1.7折。
        - **南方航空 CZ3151**：08:30宝安T3出发，11:45到达大兴国际机场，空客321执飞，经济舱约1.6折。

        ### 小贴士
        - 以上所有航班价格及折扣信息基于查询时点，实际以预订时实时查询为准。
        """
        let mixedAll = CtripFlightParser.offers(mixed, query: "深圳到北京，明天上午的", at: at)
        let mixedOffers = mixedAll.filter { !$0.isSchedule }
        expect(mixedAll.filter(\.isSchedule).count == 7 && mixedAll.filter(\.isSchedule).allSatisfy { $0.cardPrice == "票价待查" && $0.flightSpecificBookingURL == nil }, "Seven network timetables have reference cards with no quoted fare or booking link")
        expect(mixedOffers.count == 5, "Only five explicitly scoped Ctrip list rows become fare cards")
        expect(mixedOffers.map(\.cardPrice) == ["1270元 · 不含机建燃油税费", "1305元 · 不含机建燃油税费", "1660元 · 不含机建燃油税费", "600元 · 不含机建燃油税费", "1830元 · 不含机建燃油税费"], "Compact bullet prices use actual monetary amounts, never nearby discount percentages")
        expect(mixedOffers.allSatisfy { $0.leg(departure: true).date == "2026-10-25" && $0.leg(departure: false).date == "2026-10-26" }, "Explicit block dates and next-day arrivals retain real calendar dates")
        expect(mixedOffers.allSatisfy { $0.leg(departure: true).airport == "深圳宝安国际机场T3" }, "Shared origin belongs only to the stated official block")
        expect(mixedOffers[0].leg(departure: false).airport == "北京大兴国际机场T3" && mixedOffers[3].leg(departure: false).airport == "北京首都国际机场T3", "Each row retains its own destination airport")
        expect(mixedOffers.allSatisfy { $0.cardWarnings == ["非上午出发，仅作其他时段参考"] }, "Night flights visibly fail the user's morning constraint")
        let mixedNarrative = CtripFlightParser.narrative(mixed, representedBy: mixedOffers)
        expect(mixedNarrative.contains("未检索到上午出发的直飞航班"), "The unfulfilled requirement stays in normal text")
        expect(mixedNarrative.contains("### 上午直飞航班（网络来源，仅供参考）") && mixedNarrative.contains("ZH9101") && mixedNarrative.contains("CZ3151"), "All seven network references remain as text with their source caveat")
        expect(!mixedNarrative.contains("1270元") && !mixedNarrative.contains("22:00出发"), "Represented compact fares and times are not repeated as the full source list")
        expect(mixedOffers[0].cardSupplement.contains("空客321执飞") && mixedOffers[3].cardSupplement.contains("该路线直飞最低价") && !mixedNarrative.contains("MU6670"), "Compact-row details stay inside their matching cards")
        let replay = CtripFlightParser.offers(mixed, query: "深圳到北京，明天上午的", at: Date(timeIntervalSince1970: 2_000_000_000))
        expect(replay.map { $0.leg(departure: true).date } == mixedAll.map { $0.leg(departure: true).date }, "Replaying archived results cannot reinterpret tomorrow from the current date")
        let noDate = "来源：携程官方查询\n### 携程官方航班\n- 东方航空 MU6670：22:00出发，次日00:50到达北京大兴，经济舱约1270元。"
        expect(CtripFlightParser.offers(noDate, query: "明天", at: at).isEmpty, "Compact cards require a stated source date instead of guessing from relative query text")
        let network = "来源：携程官方查询\n### 网络来源\n### ZH9101\n出发时间：07:00\n到达时间：10:15\n参考价：1700元"
        let referenceCards = CtripFlightParser.offers(network, query: "明天")
        expect(referenceCards.count == 1 && referenceCards[0].isSchedule && referenceCards[0].cardPrice == "票价待查" && !referenceCards[0].details.contains("1700元"), "Network headings become timetable cards while reference amounts never become live fares")
        expect(CtripFlightParser.narrative(network, representedBy: mixedOffers) == network, "Unrepresented network source text cannot be swallowed")
        let nightArrival = CtripFlightOffer(id: "fixture", title: "CA1234", details: "出发时间：20:00\n到达时间：23:50", price: "610元", bookingURL: nil, query: "上午到达北京", queriedAt: at)
        expect(!nightArrival.cardWarnings.isEmpty, "Morning arrival constraints check the arrival leg")
        var unrestricted = nightArrival; unrestricted.query = "上午或晚上都可以"
        expect(unrestricted.cardWarnings.isEmpty, "Unrestricted alternatives do not acquire a false mismatch warning")

        let table = """
        来源：携程官方查询
        ### 携程官方航班
        查询日期2026年10月31日，价格未含税费。
        | 航班号 | 航空公司 | 出发时间 | 到达时间 | 出发机场 | 到达机场 | 经济舱参考价 | 舱位 | 机型 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | CA1234 | 中国国际航空 | 23:00 | 次日01:00 | 深圳宝安T3 | 北京首都T3 | 600元 | 经济舱 | 波音737 |
        | MU1234 | 东方航空 | 08:00 | 10:00 | 深圳宝安T3 | 北京大兴 | 610元 | 未核实舱位 | 空客321 |

        ### 网络来源，仅供参考
        | 航班号 | 出发时间 | 到达时间 | 价格 |
        | --- | --- | --- | --- |
        | HU1234 | 09:00 | 11:00 | 700元 |
        """
        let tableAll = CtripFlightParser.offers(table, query: "上午深圳到北京", at: at)
        let tableOffers = tableAll.filter { !$0.isSchedule }
        expect(tableAll.filter(\.isSchedule).count == 1 && tableAll.last?.cardPrice == "票价待查", "A network timetable table gets a distinct unpriced card")
        expect(tableOffers.count == 2 && tableOffers[0].cardPrice == "600元 · 未含税费", "Typed official table rows are supported without adopting a later network table")
        expect(tableOffers[0].leg(departure: false).date == "2026-11-01", "Next-day table arrival crosses the month boundary correctly")
        expect(!tableOffers[0].cardWarnings.isEmpty && tableOffers[1].cardWarnings.isEmpty, "Each table row's time constraint is evaluated independently")
        let tableNarrative = CtripFlightParser.narrative(table, representedBy: tableOffers)
        expect(!tableNarrative.contains("| CA1234") && !tableNarrative.contains("| MU1234"), "Fully represented rows and duplicate table detail are removed")
        expect(tableOffers[0].cardSupplement.contains("波音737") && tableOffers[1].cardSupplement.contains("未核实舱位") && tableOffers[1].cardSupplement.contains("空客321") && !tableNarrative.contains("波音737"), "Table fields and unverified metadata remain in their matching cards")
        expect(tableNarrative.contains("| HU1234") && tableNarrative.contains("网络来源，仅供参考"), "Untrusted-source tables stay intact as reference text")
        let partial = table.replacingOccurrences(of: "| MU1234 |", with: "| 无航班号 |")
        let partialOffers = CtripFlightParser.offers(partial, query: "test", at: at)
        expect(CtripFlightParser.narrative(partial, representedBy: partialOffers).contains("| CA1234"), "Partially unsupported tables retain the complete original table instead of broken leftover rows")
        expect(CtripFlightParser.sourceDate("2026年2月30日") == nil && CtripFlightParser.nextDate("2026-12-31") == "2027-01-01", "Calendar dates reject invalid days and advance years correctly")
        let staleNetworkCard = CtripFlightOffer(id: "old-network", title: "深圳航空 ZH9101", details: "出发时间：07:00\n价格：1700元", price: "1700元", bookingURL: nil, query: "明天上午", queriedAt: at)
        expect(CtripFlightParser.legacyFallbackOffers([mixedOffers[0], staleNetworkCard], in: mixed) == [mixedOffers[0]], "Legacy fallback cannot resurrect a previously misclassified network flight card")
        let sameCodeMixed = "### 携程官方结果\nMU6670 暂无结构化详情\n### 网络参考\nMU6670 参考价格1270元"
        expect(CtripFlightParser.legacyFallbackOffers([mixedOffers[0]], in: sameCodeMixed).isEmpty, "The same code across conflicting source scopes is conservatively withheld")
        expect(CtripFlightParser.legacyFallbackOffers([staleNetworkCard], in: "旧版不支持的展示格式，ZH9101 07:00 价格1700元") == [staleNetworkCard], "Unsupported but unclassified formats retain compatible old cards")
        expect(CtripFlightParser.legacyFallbackOffers([staleNetworkCard], in: "来源：携程官方查询\n旧版详情 ZH9101") == [staleNetworkCard], "An unrelated source format is not assumed to be a network reference")
        var identityInDetails = staleNetworkCard; identityInDetails.title = "旧版航班"; identityInDetails.details = "航班号：ZH9101\n出发时间：07:00"
        expect(CtripFlightParser.legacyFallbackOffers([identityInDetails], in: "来源：网络\nZH9101 参考信息").isEmpty, "Explicit flight identities in legacy detail fields also obey the external-source boundary")
        var unidentified = staleNetworkCard; unidentified.title = "旧版航班"; unidentified.details = "旧版资料"
        expect(CtripFlightParser.legacyFallbackOffers([unidentified], in: "### 网络参考\nZH9101").count == 1, "A card with no resolvable identity is not silently matched to an unrelated external code")
        expect(CtripFlightParser.legacyFallbackOffers([staleNetworkCard], in: "### 携程官方结果\n并非网络来源\nZH9101") == [staleNetworkCard], "An explicit denial of network sourcing does not create a false external boundary")
        let combinedTimes = """
        来源：携程官方查询
        2026年10月27日上海到北京
        ### 一、KN5956（中国联合航空）
        - 航班号：KN5956
        - 起降时间：20:40 出发 → 22:55抵达，飞行约135分钟
        - 出发机场：上海虹桥国际机场 T2
        - 到达机场：北京大兴国际机场
        - 舱位：经济舱
        - 票价：370元/人（约2.3折），不含税费
        """
        let combinedCards = CtripFlightParser.offers(combinedTimes, query: "2026-10-27上海到北京，下午出发，1成人经济舱", at: at)
        expect(combinedCards.count == 1 && combinedCards[0].leg(departure: true).time == "20:40" && combinedCards[0].leg(departure: false).time == "22:55",
               "The actual phone provider's combined departure-arrow-arrival field produces both leg times")
        expect(combinedCards[0].cardMetadata.contains("约135分钟") && !combinedCards[0].cardWarnings.isEmpty,
               "Combined source duration and afternoon mismatch remain visible")
        let arrowAirports = combinedTimes.replacingOccurrences(of: "出发机场：上海虹桥国际机场 T2\n- 到达机场：北京大兴国际机场", with: "机场：上海虹桥国际机场 T2 → 北京大兴国际机场")
            .replacingOccurrences(of: "飞行约135分钟", with: "飞行时长约135分钟")
        let arrowCards = CtripFlightParser.offers(arrowAirports, query: "2026-10-27上海到北京", at: at)
        expect(arrowCards.count == 1 && arrowCards[0].leg(departure: true).airport == "上海虹桥国际机场 T2" && arrowCards[0].leg(departure: false).airport == "北京大兴国际机场", "Actual combined-test airport arrows preserve both concrete airports")
        expect(arrowCards[0].cardMetadata.contains("约135分钟"), "Combined time field accepts the provider's 飞行时长 duration label")
        let connecting = """
        来源：携程官方查询
        2026年10月26日北京到深圳
        ### 方案一：ZH1023 + ZH9140 中转
        - 航班号：第一段 ZH1023（深圳航空）/ 第二段 ZH9140（深圳航空）
        - 日期：2026-10-26
        - 起降时间：07:15 出发 → 08:30 到达中转地 / 12:25 中转出发 → 15:10 到达深圳
        - 起降机场：北京大兴国际机场 → 中转机场 → 深圳宝安国际机场 T3
        - 舱位：经济舱（约2.2折）
        - 票价：520元/人（不含税费）
        - 机型：第一段波音737 / 第二段空客320
        - 总耗时：约475分钟（含中转等待）
        ### 方案二：ZH1461 + ZH9958 中转
        - 日期：2026-10-26
        - 起降时间：06:40 出发 → 10:05 到达中转地 / 19:15 中转出发 → 21:00 到达深圳
        - 起降机场：北京首都国际机场 T3 → 贵阳龙洞堡国际机场 T3 → 深圳宝安国际机场 T3
        - 票价：610元/人（不含税费）
        ### 如何选
        预算优先可选午间抵达的方案；税费与余票仍需在携程核对。
        """
        let connectingCards = CtripFlightParser.offers(connecting, query: "北京到深圳", at: at)
        let connectingText = CtripFlightParser.narrative(connecting, representedBy: connectingCards)
        expect(connectingCards.count == 2 && connectingCards[0].leg(departure: true).time == "07:15" && connectingCards[0].leg(departure: false).time == "15:10", "Connecting cards show the first departure and final arrival, not missing times")
        expect(connectingCards[0].leg(departure: true).airport == "北京大兴国际机场" && connectingCards[0].leg(departure: false).airport == "深圳宝安国际机场 T3", "A transfer route retains both endpoint airports")
        expect(connectingCards[1].transferAirport == "贵阳龙洞堡国际机场 T3" && connectingCards[0].transferAirport == "中转机场", "Only the source's stated transfer airport is used; an unnamed connection is not invented")
        expect(connectingCards[0].cardMetadata.contains("经济舱（约2.2折）") && connectingCards[0].cardMetadata.contains("约475分钟（含中转等待）"), "Cabin discount and total journey duration remain visible on the card")
        expect(connectingCards[0].cardSupplement.contains("08:30") && connectingCards[0].cardSupplement.contains("12:25") && connectingCards[0].cardSupplement.contains("第一段波音737"), "Intermediate times and aircraft are retained in the matching card's extra details")
        expect(!connectingText.contains("ZH1023") && !connectingText.contains("ZH1461") && !connectingText.contains("起降时间") && !connectingText.contains("机型") && !connectingText.contains("520元"), "A represented transfer does not create a second flight-by-flight text list")
        expect(connectingText.contains("预算优先") && connectingText.contains("税费与余票"), "Selection advice and general qualifications remain visible once")
        let overnightTransfer = connecting.replacingOccurrences(of: "08:30 到达中转地", with: "次日 08:30 到达中转地")
        expect(CtripFlightParser.offers(overnightTransfer, query: "test", at: at)[0].leg(departure: false).date == "2026-10-27", "A next-day transfer marker also applies to its final arrival")
        let ambiguousTransfer = overnightTransfer.replacingOccurrences(of: "15:10 到达深圳", with: "次日 15:10 到达深圳")
        expect(CtripFlightParser.offers(ambiguousTransfer, query: "test", at: at)[0].leg(departure: false).date.isEmpty, "Multiple relative-day markers retain the original itinerary without inventing a final date")
        let legacyData = try JSONEncoder().encode(connectingCards[0])
        let reopenedCard = try JSONDecoder().decode(CtripFlightOffer.self, from: legacyData)
        expect(reopenedCard == connectingCards[0], "Card details survive saving and reopening the conversation")
        let sharedFares = """
        来源：携程官方查询
        ### 航班一：MU5127（中国东方航空）
        - 日期：2026年10月27日
        - 起飞：21:00，上海虹桥国际机场 T2
        - 到达：23:15，北京首都国际机场 T2
        - 参考价格：561元/人（不含税）
        ### 航班二：MU5185（中国东方航空）及共享航班
        - 日期：2026年10月27日
        - 起飞：21:05，上海浦东国际机场 T1
        - 到达：23:20，北京大兴国际机场
        - 是否含税：否，所示价格为票面价，税费另计
        - 舱位：经济舱
        - 预订链接：未提供
        该航班有4个航司可选，票价由低到高：
        - MU5185（东航自营）：420元/人（约2.0折），为当前直飞最低价
        - MF3627（厦门航空，代码共享）：615元/人（约2.9折）
        - KN6509（中国联合航空，代码共享）：970元/人（约4.6折）
        - CZ1988（中国南方航空，代码共享）：970元/人（约4.6折）
        ### 补充说明
        行李额度和退改仍需核对。
        """
        let sharedCards = CtripFlightParser.offers(sharedFares, query: "2026-10-27上海到北京，下午直飞，1成人经济舱", at: at)
        expect(sharedCards.count == 5, "A live-provider-style codeshare fare list yields five distinct fare cards")
        expect(sharedCards.allSatisfy { $0.cardWarnings == ["非下午出发，仅作其他时段参考"] }, "Real-provider night flights are visibly marked as outside the requested afternoon period")
        expect(sharedCards.map(\.cardPrice) == ["561元 · 不含税", "420元 · 不含税", "615元 · 不含税", "970元 · 不含税", "970元 · 不含税"], "Codeshare fares inherit explicit tax qualifications without borrowing another fare's amount")
        expect(sharedCards[0].leg(departure: true).time == "21:00" && sharedCards[0].leg(departure: true).airport == "上海虹桥国际机场 T2", "Short departure labels keep time and airport")
        expect(sharedCards.dropFirst().allSatisfy { $0.leg(departure: true).time == "21:05" && $0.leg(departure: true).date == "2026-10-27" && $0.leg(departure: false).airport == "北京大兴国际机场" }, "Each shared fare inherits its own parent times, date and airports")
        expect(sharedCards.allSatisfy { $0.flightSpecificBookingURL == nil && $0.bookingButtonTitle == "复制并打开携程" }, "Missing source links expose a truthful app-selection fallback")
        expect(sharedCards[2].bookingSummary.contains("MF3627") && sharedCards[2].bookingSummary.contains("615元") && !sharedCards[2].bookingSummary.contains("561元"), "Handoff text carries only the selected fare and its full search conditions")
        let sharedNarrative = CtripFlightParser.narrative(sharedFares, representedBy: sharedCards)
        expect(!sharedNarrative.contains("起飞：") && !sharedNarrative.contains("到达：") && sharedNarrative.contains("行李额度和退改仍需核对"), "Shared-card core fields are not duplicated in prose while unrepresented policy information stays available")
        let oldReply = AssistantMessage(role: "assistant", text: sharedFares, createdAt: at, flightOffers: [], flightQuery: "2026-10-27上海到北京")
        let session = CtripFlightSearchContext.latest(in: [oldReply] + (0..<16).map { .init(role: "user", text: "普通聊天\($0)") })
        expect(session?.offers.count == 5 && session?.query == oldReply.flightQuery, "Conversation flight state reparses old empty-card messages after intervening ordinary chat")
        let emptyReply = AssistantMessage(role: "assistant", text: "没有符合条件的航班", createdAt: at, flightOffers: [], flightQuery: "2026-10-28北京到成都，直飞2人")
        let emptySession = CtripFlightSearchContext.latest(in: [oldReply, emptyReply])
        expect(emptySession?.offers.isEmpty == true && emptySession?.query == emptyReply.flightQuery, "Empty searches keep complete changed conditions while clearing earlier candidates")
        let policyReply = AssistantMessage(role: "assistant", text: "工具没有返回这张票的行李额度，请在携程核对。", flightOffers: [], flightQuery: "查询2026-10-27上海到北京MU5185的行李和退改")
        let policyContext = CtripFlightSearchContext.latest(in: [oldReply, policyReply])
        expect(policyContext?.offers.count == 5 && policyContext?.query == oldReply.flightQuery,
               "A baggage-only follow-up about an exact displayed flight keeps the candidate ordering when no cards are repeated")
        var unavailablePolicy = policyReply; unavailablePolicy.text = "该航班已售罄，没有可售选项"
        expect(CtripFlightSearchContext.latest(in: [oldReply, unavailablePolicy])?.offers.isEmpty == true,
               "An explicit unavailable response never retains stale fares even for a policy follow-up")
        expect(CtripFlightSearchContext.latest(in: [.init(role: "user", text: sharedFares)]) == nil, "User-quoted provider text does not create bookable flight state")
        var linked = sharedCards[0]
        for generic in ["https://flights.ctrip.com/booking", "https://m.ctrip.com/html5/flight/order?allianceid=123", "https://m.ctrip.com/account/detail/123"] {
            linked.bookingURL = URL(string: generic)
            expect(linked.flightSpecificBookingURL == nil, "A generic booking/account page is never labelled a flight-specific handoff")
        }
        linked.bookingURL = URL(string: "https://flights.ctrip.com/order/verified-source-id")
        expect(linked.flightSpecificBookingURL == linked.bookingURL && linked.bookingButtonTitle == "去携程预订", "An explicit source booking resource can be attempted as App-only prebooking without claiming payment")
        let prefixedFare = "来源：携程官方查询\n2026年10月26日北京到上海\n### HO1254\n起降时间：21:20 出发 - 23:30 到达\n当前票价：经济舱约420元（2.4折，不含税费）"
        let prefixedCards = CtripFlightParser.offers(prefixedFare, query: "2026年10月26日北京到上海")
        expect(prefixedCards.count == 1 && prefixedCards[0].cardPrice == "约420元 · 不含税费" && !prefixedCards[0].isSchedule, "Actual current-fare alias and cabin prefix preserve the provider amount and qualifier")
        let pipeFare = "来源：携程官方查询\n## 2026-10-30 深圳→北京 上午直飞（1成人经济舱）\n- **ZH9101**｜07:00宝安起飞，10:15首都到达｜经济舱 1280元"
        let pipeCards = CtripFlightParser.offers(pipeFare, query: "2026年10月30日深圳到北京上午")
        expect(pipeCards.count == 1 && pipeCards[0].cardPrice == "1280元" && pipeCards[0].leg(departure: true).airport == "宝安", "Actual full-width-pipe flight rows preserve time, airport and fare")
        expect(referenceCards[0].bookingButtonTitle == "去携程查价" && referenceCards[0].bookingSummary.contains("尚未核价"), "Timetable handoff copies an unpriced reference and asks Ctrip to check the fare")
        let anonymousSchedule = "来源：携程官方查询\n以下时刻来源于网络，仅供参考\n### 18:00 虹桥T2 - 20:15 首都T2\n日期：2026-10-29\n票价：待核实"
        let anonymousCards = CtripFlightParser.offers(anonymousSchedule, query: "2026-10-29上海到北京")
        expect(anonymousCards.count == 1 && anonymousCards[0].isSchedule && anonymousCards[0].cardTitle == "航班时刻参考" && anonymousCards[0].leg(departure: true).airport == "虹桥T2", "A timetable with two explicit times and airports can have a reference card without inventing a flight number")
        let shortenedAirports = prefixedFare.replacingOccurrences(of: "当前票价：", with: "起降机场：北京大兴 → 上海浦东T2\n当前票价：")
        expect(CtripFlightParser.offers(shortenedAirports, query: "test").first?.leg(departure: true).airport == "北京大兴", "Explicit short airport names in a combined field remain usable")
        let nestedPrice = "来源：携程官方查询\n### ZH1522（深圳航空）\n日期：2026-10-29\n起降时间：18:30 出发 / 20:55 到达\n机场/航站楼：上海虹桥国际机场 T2 → 北京首都国际机场 T3\n舱位：经济舱（票价930元/人，折扣63%，未税）\n### MU5121 — 时刻参考／票价待查\n起降时间：18:00 出发 / 20:15 到达\n票价：待查"
        let nestedCards = CtripFlightParser.offers(nestedPrice, query: "上海到北京")
        expect(nestedCards.count == 2 && !nestedCards[0].isSchedule && nestedCards[0].cardPrice == "930元 · 未税" && nestedCards[1].isSchedule, "A live mixed response retains the fare nested in cabin metadata and a distinct timetable card")
        expect(nestedCards[0].leg(departure: true).airport == "上海虹桥国际机场 T2", "The live airport/terminal field alias preserves the quoted flight airports")
        let arrowReference = "来源：携程官方查询\n## 上午时刻参考（票价待查）\n- **CA3401 / 国航**：07:00 宝安T3 → 10:15 首都T3，空客系列，每日执飞"
        let arrowTimetableCards = CtripFlightParser.offers(arrowReference, query: "2026-10-30深圳到北京上午")
        expect(arrowTimetableCards.count == 1 && arrowTimetableCards[0].isSchedule && arrowTimetableCards[0].leg(departure: true).time == "07:00" && arrowTimetableCards[0].leg(departure: false).airport == "首都T3", "Actual arrow timetable bullets become reference cards without inventing a price or flight date")
        let liveGroupReply = #"""
        来源：携程官方查询 · 25 Oct 2026 at 7:12 pm
        
        已为您查询到2026年10月26日北京至深圳单程机票（1位成人、经济舱）的航班信息，以下数据均来自携程机票接口实际返回，按直飞优先、中转补充的顺序展示。所有票价均为不含税费参考价，税费、含税总价、行李额度及退改规则接口未返回，统一标注为"待核实"。
        ## 一、直飞航班（共10班，按参考价从低到高）
        
        ### 厦门航空 MF8335
        - **航班号**：MF8335（厦门航空）
        - **日期**：2026-10-26
        - **起降时间**：07:30 出发 → 10:55 到达
        - **出发机场**：北京大兴国际机场
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：空客321
        - **舱位**：经济舱（1.9折）
        - **参考价**：600元（不含税费）
        - **总耗时**：约3小时25分钟
        - **标签**：此路线直飞最低价
        
        ### 海南航空 HU7715
        - **航班号**：HU7715（海南航空）
        - **日期**：2026-10-26（跨日到达）
        - **起降时间**：20:30 出发 → 次日00:05 到达
        - **出发机场**：北京首都国际机场 T2
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：波音787
        - **舱位**：经济舱（2.2折）
        - **参考价**：700元（不含税费）
        - **总耗时**：约3小时35分钟
        
        ### 厦门航空 MF8349
        - **航班号**：MF8349（厦门航空）
        - **日期**：2026-10-26
        - **起降时间**：16:15 出发 → 19:55 到达
        - **出发机场**：北京大兴国际机场
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：空客321
        - **舱位**：经济舱（2.2折）
        - **参考价**：700元（不含税费）
        - **总耗时**：约3小时40分钟
        
        ### 东方航空 MU6671
        - **航班号**：MU6671（东方航空）
        - **日期**：2026-10-26
        - **起降时间**：07:00 出发 → 10:15 到达
        - **出发机场**：北京大兴国际机场
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：空客321-200
        - **舱位**：经济舱（2.4折）
        - **参考价**：720元（不含税费）
        - **总耗时**：约3小时15分钟
        
        ### 海南航空 HU7713
        - **航班号**：HU7713（海南航空）
        - **日期**：2026-10-26
        - **起降时间**：19:30 出发 → 23:00 到达
        - **出发机场**：北京首都国际机场 T2
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：波音787
        - **舱位**：经济舱（2.5折）
        - **参考价**：800元（不含税费）
        - **总耗时**：约3小时30分钟
        
        ### 中联航 KN5851
        - **航班号**：KN5851（中国联合航空）
        - **日期**：2026-10-26
        - **起降时间**：13:20 出发 → 16:50 到达
        - **出发机场**：北京大兴国际机场
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：波音737
        - **舱位**：经济舱（3.1折）
        - **参考价**：830元（不含税费）
        - **总耗时**：约3小时30分钟
        
        ### 深圳航空 ZH9110
        - **航班号**：ZH9110（深圳航空）
        - **日期**：2026-10-26（跨日到达）
        - **起降时间**：21:00 出发 → 次日00:40 到达
        - **出发机场**：北京首都国际机场 T3
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：空客330-300
        - **舱位**：经济舱（2.3折）
        - **参考价**：830元（不含税费）
        - **总耗时**：约3小时40分钟
        
        ### 东方航空 MU6667
        - **航班号**：MU6667（东方航空）
        - **日期**：2026-10-26
        - **起降时间**：17:00 出发 → 20:20 到达
        - **出发机场**：北京大兴国际机场
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：空客321
        - **舱位**：经济舱（2.9折）
        - **参考价**：850元（不含税费）
        - **总耗时**：约3小时20分钟
        
        ### 海南航空 HU7709
        - **航班号**：HU7709（海南航空）
        - **日期**：2026-10-26
        - **起降时间**：14:30 出发 → 18:00 到达
        - **出发机场**：北京首都国际机场 T2
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：空客330
        - **舱位**：经济舱（2.6折）
        - **参考价**：850元（不含税费）
        - **总耗时**：约3小时30分钟
        
        ### 深圳航空 ZH9114
        - **航班号**：ZH9114（深圳航空）
        - **日期**：2026-10-26
        - **起降时间**：13:30 出发 → 17:05 到达
        - **出发机场**：北京首都国际机场 T3
        - **到达机场**：深圳宝安国际机场 T3
        - **机型**：波音737
        - **舱位**：经济舱（2.4折）
        - **参考价**：850元（不含税费）
        - **总耗时**：约3小时35分钟
        ## 二、中转航班（选取参考价较低的方案）
        
        ### 深圳航空中转（经襄阳刘集，停留约12小时50分钟）
        - **第一段**：ZH9151，07:55 北京首都T3 → 10:00 襄阳刘集T2，波音737，约2小时05分钟
        - **第二段**：ZH8934，22:50 襄阳刘集T2 → 次日01:10 深圳宝安T3，波音737，约2小时20分钟
        - **中转地**：襄阳刘集机场，停留约12小时50分钟
        - **舱位**：经济舱（1.7折）
        - **参考价**：400元（不含税费）
        - **总耗时**：约17小时15分钟
        - **标签**：06:00-09:00时段最低价
        
        ### 国航中转（经盐湖，停留约3小时55分钟）
        - **第一段**：CA8623，07:15 北京大兴 → 08:30 盐湖，波音737，约1小时15分钟
        - **第二段**：CA3640，12:25 盐湖 → 15:10 深圳宝安T3，空客320，约2小时45分钟
        - **中转地**：盐湖国际机场，停留约3小时55分钟
        - **舱位**：经济舱（2.2折）
        - **参考价**：520元（不含税费）
        - **总耗时**：约7小时55分钟
        - **标签**：06:00-09:00时段最低价
        
        ### 深圳航空中转（经盐湖，停留约3小时55分钟）
        - **第一段**：ZH1023，07:15 北京大兴 → 08:30 盐湖，波音737，约1小时15分钟
        - **第二段**：ZH9140，12:25 盐湖 → 15:10 深圳宝安T3，空客320，约2小时45分钟
        - **中转地**：盐湖国际机场，停留约3小时55分钟
        - **舱位**：经济舱（2.2折）
        - **参考价**：520元（不含税费）
        - **总耗时**：约7小时55分钟
        - **标签**：06:00-09:00时段最低价
        
        ### 东海航空 DZ6210（经停航班）
        - **航班号**：DZ6210（东海航空）
        - **日期**：2026-10-26
        - **起降时间**：08:45 北京大兴 → 13:10 深圳宝安T3
        - **机型**：波音737
        - **舱位**：经济舱（2.2折）
        - **参考价**：530元（不含税费）
        - **总耗时**：约4小时25分钟
        - **说明**：该航班为经停航班（非直飞，中间停靠一站）
        
        ### 国航中转（经贵阳龙洞堡，停留约9小时10分钟）
        - **第一段**：CA1461，06:40 北京首都T3 → 10:05 贵阳龙洞堡T3，空客321，约3小时25分钟
        - **第二段**：CA3886，19:15 贵阳龙洞堡T3 → 21:00 深圳宝安T3，空客320，约1小时45分钟
        - **中转地**：贵阳龙洞堡国际机场，停留约9小时10分钟
        - **舱位**：经济舱（1.4折）
        - **参考价**：610元（不含税费）
        - **总耗时**：约14小时20分钟
        
        ### 国航中转（经南京禄口，停留约2小时10分钟）
        - **第一段**：CA8369，15:20 北京大兴 → 17:10 南京禄口T1，波音737，约1小时50分钟
        - **第二段**：CA3696，19:20 南京禄口T2 → 21:55 深圳宝安T3，空客320，约2小时35分钟
        - **中转地**：南京禄口国际机场，停留约2小时10分钟
        - **舱位**：经济舱（1.3折）
        - **参考价**：630元（不含税费）
        - **总耗时**：约6小时35分钟
        ## 三、方案对比与选择建议
        
        - **直飞最低价**：MF8335（07:30大兴出发），参考价600元，约3小时25分钟到达，兼顾价格与效率。
        - **中转最低价**：ZH9151+ZH8934（经襄阳刘集），参考价400元，但中转等待近13小时、总耗时超17小时，适合预算优先且时间充裕的场景。
        - **中转效率较优**：CA8369+CA3696（经南京禄口），参考价630元，中转仅2小时10分钟、总耗时约6小时35分钟，在中转方案中耗时最短。
        
        
        ## 四、税费、行李及退改规则说明
        
        以上所有航班的参考价均为**不含税费**的票价，以下信息接口未返回实际数据：
        
        - **税费（机建燃油等）**：待核实
        - **含税总价**：待核实（不自行估算，不计算机建燃油差额）
        - **行李额度**：待核实
        - **退改签规则**：待核实
        
        以上信息以携程机票详情页实时展示为准，您可在选择具体航班后查看完整税费、行李政策及退改规则。本次仅做查询展示，不涉及订单创建或支付。
        """#

        let liveGroupCards = CtripFlightParser.offers(liveGroupReply, query: "2026-10-26北京到深圳，直飞和中转", at: at)
        let liveGroupNarrative = CtripFlightParser.narrative(liveGroupReply, representedBy: liveGroupCards)
        expect(liveGroupCards.count == 16 && liveGroupCards.allSatisfy { !$0.isSchedule }, "The actual ten direct plus six transfer/stopover source options become sixteen complete quoted cards")
        expect(liveGroupCards[10].cardTitle == "ZH9151 + ZH8934 · 深圳航空" && liveGroupCards[10].cardPrice == "400元 · 不含税费", "Two leg bullets belong to one journey with its own airline and whole-itinerary fare")
        expect(liveGroupCards[10].leg(departure: true).time == "07:55" && liveGroupCards[10].leg(departure: true).airport == "北京首都T3" && liveGroupCards[10].leg(departure: false).time == "01:10" && liveGroupCards[10].leg(departure: false).airport == "深圳宝安T3", "A segmented journey displays its actual first departure and final arrival endpoints")
        expect(liveGroupCards[10].leg(departure: true).date == "2026-10-26" && liveGroupCards[10].leg(departure: false).date == "2026-10-27", "The source's overall query date and explicit next-day leg produce correct calendar dates")
        expect(liveGroupCards[10].transferAirport == "襄阳刘集机场，停留约12小时50分钟" && liveGroupCards[10].cardMetadata.contains("约17小时15分钟"), "Source transfer location and whole-trip duration remain on their own card")
        expect(liveGroupCards[10].cardSegments.count == 2 && liveGroupCards[10].cardSegments[0].text.contains("ZH9151，07:55 北京首都T3 → 10:00 襄阳刘集T2") && liveGroupCards[10].cardSegments[1].text.contains("ZH8934，22:50 襄阳刘集T2 → 次日01:10 深圳宝安T3"), "Each leg's source text survives intact for direct display inside its journey card, including the next-day marker")
        expect(liveGroupCards[13].cardTitle == "DZ6210 · 东海航空" && liveGroupCards[13].cardMetadata.contains("经停") && liveGroupCards[13].leg(departure: true).airport == "北京大兴" && liveGroupCards[13].leg(departure: false).airport == "深圳宝安T3", "The explicit stopover type and combined-field endpoint airports are visible without guessing an intermediate airport")
        expect(liveGroupCards[15].cardTitle == "CA8369 + CA3696 · 国航" && liveGroupCards[15].cardPrice == "630元 · 不含税费" && liveGroupCards[15].cardMetadata.contains("约6小时35分钟"), "The last actual transfer remains a separate complete plan instead of being cut off by leg cards")
        expect(liveGroupCards[0].cardSupplement.contains("标签：此路线直飞最低价") && liveGroupCards[13].cardSupplement.contains("说明：该航班为经停航班"), "Per-flight tags and stopover explanations stay with the appropriate card")
        expect(!liveGroupNarrative.contains("### ") && !liveGroupNarrative.contains("**第一段**") && !liveGroupNarrative.contains("**第二段**") && !liveGroupNarrative.contains("**起降时间**") && !liveGroupNarrative.contains("**机型**") && !liveGroupNarrative.contains("**标签**"), "The actual reply has no second flight-by-flight field or heading list outside its cards")
        expect(!liveGroupNarrative.contains("## 一、直飞航班") && !liveGroupNarrative.contains("## 二、中转航班") && liveGroupNarrative.contains("## 三、方案对比与选择建议") && liveGroupNarrative.contains("## 四、税费、行李及退改规则说明"), "Only empty category headings disappear; substantive recommendations and qualifications retain their headings")
        let transferStart = liveGroupReply.range(of: "### 深圳航空中转（经襄阳刘集")!.lowerBound
        let transferEnd = liveGroupReply.range(of: "### 国航中转（经盐湖")!.lowerBound
        let sourceIntro = String(liveGroupReply[..<liveGroupReply.range(of: "## 一、")!.lowerBound])
        let transferBody = String(liveGroupReply[transferStart..<transferEnd])
        let transferOnly = sourceIntro + transferBody
        let noDateTransfer = "来源：携程官方查询\n" + transferBody
        let noDateCards = CtripFlightParser.offers(noDateTransfer, query: "2099年12月31日北京到深圳", at: Date(timeIntervalSince1970: 3_000_000_000))
        expect(noDateCards.count == 1 && noDateCards[0].leg(departure: true).date.isEmpty && noDateCards[0].leg(departure: false).date == "次日", "A missing source date stays unknown despite a dated user query and later current time")
        let localDated = transferOnly.replacingOccurrences(of: "- **第一段**", with: "- 日期：2026-11-01\n- **第一段**")
        let localDatedCards = CtripFlightParser.offers(localDated, query: "test", at: at)
        expect(localDatedCards[0].leg(departure: true).date == "2026-11-01" && localDatedCards[0].leg(departure: false).date == "2026-11-02", "An explicit group date takes precedence over a source-wide date")
        let ambiguousIntro = transferOnly.replacingOccurrences(of: "2026年10月26日北京", with: "2026年10月26日至2026年10月27日北京")
        expect(CtripFlightParser.offers(ambiguousIntro, query: "test", at: at)[0].leg(departure: true).date.isEmpty, "A source date range cannot silently become one itinerary date")
        let timestampOnly = noDateTransfer.replacingOccurrences(of: "来源：携程官方查询", with: "来源：携程官方查询 · 2026-10-25 19:12")
        expect(CtripFlightParser.offers(timestampOnly, query: "test", at: at)[0].leg(departure: true).date.isEmpty, "A query retrieval timestamp is not the departure date")
        let undatedAfterFlight = "来源：携程官方查询\n### MU1234\n日期：2026-12-30\n起降时间：08:00出发→10:00到达\n参考价：900元\n" + transferBody
        expect(CtripFlightParser.offers(undatedAfterFlight, query: "test", at: at).last!.leg(departure: true).date.isEmpty, "An earlier independent flight's date never leaks into an undated transfer")
        let explicitLegDates = noDateTransfer.replacingOccurrences(of: "ZH9151，07:55", with: "ZH9151，2026-10-26 07:55").replacingOccurrences(of: "次日01:10", with: "2026-10-27 01:10")
        let explicitLegCards = CtripFlightParser.offers(explicitLegDates, query: "test", at: at)
        expect(explicitLegCards[0].leg(departure: true).date == "2026-10-26" && explicitLegCards[0].leg(departure: false).date == "2026-10-27", "Explicit calendar dates on the legs also bind their itinerary without an overall date")
        let noNextDay = transferOnly.replacingOccurrences(of: "次日01:10", with: "01:10")
        expect(CtripFlightParser.offers(noNextDay, query: "test", at: at)[0].leg(departure: false).date.isEmpty, "An unmarked midnight wrap does not invent a next-day arrival date")
        let malformedLeg = transferOnly.replacingOccurrences(of: "次日01:10", with: "次日1:10")
        expect(CtripFlightParser.offers(malformedLeg, query: "test", at: at).isEmpty && CtripFlightParser.narrative(malformedLeg, representedBy: []) == malformedLeg, "A malformed leg is kept intact in source text and does not split into independently bookable cards")
        let splitGroups = "来源：携程官方查询\n### 深圳航空中转\n- 第一段：ZH9151，07:55 北京首都T3 → 10:00 襄阳刘集T2\n- 参考价：400元\n### 另一中转方案\n- 第二段：ZH8934，22:50 襄阳刘集T2 → 次日01:10 深圳宝安T3\n- 参考价：520元"
        expect(CtripFlightParser.offers(splitGroups, query: "test", at: at).isEmpty, "Two incomplete neighboring groups cannot combine their legs or fares")
        let unsupportedFourLegs = transferOnly + "\n- 第三段：ZH9911，02:00 深圳宝安T3 → 03:00 广州白云T1\n- 第四段：ZH9912，04:00 广州白云T1 → 05:00 深圳宝安T3"
        expect(CtripFlightParser.offers(unsupportedFourLegs, query: "test", at: at).isEmpty && CtripFlightParser.narrative(unsupportedFourLegs, representedBy: []) == unsupportedFourLegs, "An unsupported four-leg source remains intact rather than presenting only its first three legs or isolated leg cards")
        let segmentPriceOnly = transferOnly.replacingOccurrences(of: "- **参考价**：400元（不含税费）\n", with: "").replacingOccurrences(of: "波音737，约2小时05分钟", with: "波音737，约2小时05分钟，参考价：200元")
        let legPriceCards = CtripFlightParser.offers(segmentPriceOnly, query: "test", at: at)
        expect(legPriceCards.count == 1 && legPriceCards[0].isSchedule && legPriceCards[0].cardPrice == "票价待查" && legPriceCards[0].cardSegments[0].text.contains("参考价：200元"), "A price inside one leg stays source detail and never becomes the itinerary's quote")
        let neighboringFare = segmentPriceOnly + "\n" + transferBody.replacingOccurrences(of: "深圳航空中转", with: "另一深圳航空中转").replacingOccurrences(of: "400元", with: "520元")
        let neighboringCards = CtripFlightParser.offers(neighboringFare, query: "test", at: at)
        expect(neighboringCards.count == 2 && neighboringCards[0].isSchedule && neighboringCards[1].cardPrice == "520元 · 不含税费", "A neighboring complete itinerary cannot donate its price to an unpriced one")
        let externalTransfer = transferOnly.replacingOccurrences(of: "来源：携程官方查询", with: "来源：网络参考")
        let externalTransferCards = CtripFlightParser.offers(externalTransfer, query: "test", at: at)
        expect(externalTransferCards.count == 1 && externalTransferCards[0].isSchedule && externalTransferCards[0].cardPrice == "票价待查" && externalTransferCards[0].flightSpecificBookingURL == nil, "A structured transfer from an external source stays unpriced reference data")
        var nonStop = liveGroupCards[13]; nonStop.title = "东海航空 DZ6210（非经停航班）"; nonStop.details = nonStop.details.replacingOccurrences(of: "该航班为经停航班（非直飞，中间停靠一站）", with: "该航班并非经停航班")
        expect(!nonStop.cardMetadata.contains("经停"), "A negated stopover description does not create a stopover label")
        let invalidPlans = (0..<30).map { "### CA\(5000 + $0)\n价格：待核实" }.joined(separator: "\n")
        let validPlans = (0..<30).map { "### MF\(6000 + $0)\n日期：2026-10-26\n起降时间：08:00出发→10:00到达\n参考价：\(600 + $0)元" }.joined(separator: "\n")
        let boundedSource = "来源：携程官方查询\n" + invalidPlans + "\n" + validPlans
        let boundedCards = CtripFlightParser.offers(boundedSource, query: "test", at: at)
        expect(boundedCards.count == 30 && boundedCards.first!.cardTitle.contains("MF6000") && boundedCards.last!.cardTitle.contains("MF6029"), "All thirty valid source options are retained independently of UI pagination; invalid headings do not spend an allowance")
        expect(CtripFlightParser.narrative(boundedSource, representedBy: Array(boundedCards.prefix(24))).contains("MF6029"), "The lossless narrative still preserves any valid option intentionally omitted by a caller")
        let liveRecommendation = CtripFlightParser.recommendation(liveGroupReply, representedBy: liveGroupCards)
        expect(liveRecommendation.preferredOfferID == liveGroupCards[3].id, "The actual reply selects fewer transfers then shortest total duration, independently of provider recommendation")
        expect(liveRecommendation.advice.isEmpty && liveRecommendation.sortDescription.contains("中转次数少 → 总耗时短 → 同口径报价低 → 起飞早"), "Generic provider advice is replaced by an explicit deterministic sorting description")
        expect(!["MF8335", "600元", "07:30", "3小时25分钟", "2026", "机场", "空客"].contains(where: liveRecommendation.advice.contains), "Recommendation text does not repeat flight identities, amounts, dates, times, airports, aircraft or duration already on cards")
        expect(!liveRecommendation.advice.contains("查询到") && !liveRecommendation.advice.contains("1位成人"), "Query introduction and passenger conditions are not repeated as advice")
        expect(["税费", "含税总价", "行李额度", "退改签规则", "待核实"].allSatisfy(liveRecommendation.commonNotes.contains) && !liveRecommendation.commonNotes.contains("600元"), "The actual common limitations remain in one shared note without repeating a fare")
        expect(liveRecommendation.commonNotes.contains("以携程详情页为准"), "The common note retains the source's explicit final-verification qualification")
        let fallbackRecommendation = CtripFlightParser.recommendation("", representedBy: [liveGroupCards[1], liveGroupCards[0]])
        expect(fallbackRecommendation.preferredOfferID == liveGroupCards[0].id, "The deterministic policy is independent of source recommendation and ranks shorter total duration before price")
        expect(!["最低", "最优", "便宜", "效率"].contains(where: fallbackRecommendation.advice.contains), "The cautious fallback invents no comparative advantage")
        let namedRecommendation = "## 选择建议\n- 综合推荐：MF8349，衔接更方便。"
        expect(CtripFlightParser.recommendation(namedRecommendation, representedBy: liveGroupCards).preferredOfferID == liveGroupCards[3].id, "An explicit provider recommendation cannot override deterministic user/default policy")
        let groupRecommendation = "## 选择建议\n- 推荐方案：ZH9151+ZH8934，适合预算优先且时间充裕的场景。"
        expect(CtripFlightParser.recommendation(groupRecommendation, representedBy: liveGroupCards).preferredOfferID == liveGroupCards[3].id, "A recommended connecting itinerary cannot displace a better policy-ranked direct option")
        var outsideConstraints = liveGroupCards[1]; outsideConstraints.query = "上午到达深圳"
        let rejectedRecommendation = CtripFlightParser.recommendation("## 选择建议\n- 综合推荐：HU7715，衔接更方便。", representedBy: [outsideConstraints, liveGroupCards[0]])
        expect(!outsideConstraints.cardWarnings.isEmpty && rejectedRecommendation.preferredOfferID == liveGroupCards[0].id && !rejectedRecommendation.advice.contains("衔接更方便"), "A recommended quote that violates a hard condition cannot become preferred or contribute an unqualified benefit")
        let allRejected = CtripFlightParser.recommendation("本次未检索到上午到达的直飞航班。", representedBy: [outsideConstraints])
        expect(allRejected.preferredOfferID == nil && allRejected.advice.isEmpty && allRejected.sortDescription.contains("暂无硬条件均已确认满足"), "No violating option becomes preferred and absence of qualifying quotes is explicit")
        let referenceRecommendation = CtripFlightParser.recommendation("", representedBy: referenceCards)
        expect(referenceRecommendation.preferredOfferID == nil && referenceRecommendation.advice.isEmpty && referenceRecommendation.sortDescription.contains("暂无硬条件均已确认满足"), "Unpriced schedules cannot be promoted to a qualifying quoted fare")
        let missingRecommendation = CtripFlightParser.recommendation("", representedBy: [])
        expect(missingRecommendation.preferredOfferID == nil && missingRecommendation.advice.isEmpty && missingRecommendation.sortDescription.contains("暂无可比较方案"), "An empty result states its availability without generic advice")
        let unknownFlightRecommendation = CtripFlightParser.recommendation("## 选择建议\n- 综合推荐：ZZ9999，衔接更方便。", representedBy: liveGroupCards)
        expect(unknownFlightRecommendation.preferredOfferID == liveGroupCards[3].id, "A code absent from actual cards cannot alter deterministic selection")
        let recommendingLast = boundedSource + "\n## 选择建议\n- 综合推荐：MF6029，衔接更方便。"
        let displayCards = CtripFlightParser.displayOrder(recommendingLast, representedBy: boundedCards)
        expect(displayCards.count == 30 && displayCards == boundedCards, "Provider recommendation does not reorder equal policy keys and all thirty options remain")
        let displayedSearch = CtripFlightSearchContext.latest(in: [.init(role: "assistant", text: recommendingLast, createdAt: at, flightOffers: boundedCards, flightQuery: "2026-10-26北京到深圳")])!
        expect(displayedSearch.offers.map(\.id) == displayCards.map(\.id), "Search-context ordinal positions use the same recommendation-first order as the UI")
        expect(CtripFlightParser.displayOrder(recommendingLast, representedBy: displayCards) == displayCards, "Display ordering is stable and idempotent")
        var duplicateA = boundedCards[0]; duplicateA.id = "legacy-fixture"
        var duplicateB = boundedCards[1]; duplicateB.id = "legacy-fixture"
        let duplicateSources = [duplicateA, duplicateB, boundedCards[2]]
        let duplicateOrder = CtripFlightParser.displayOrder("", representedBy: duplicateSources)
        expect(duplicateOrder.count == 3 && duplicateOrder == duplicateSources, "Selecting a legacy ID shared by distinct source offers moves one occurrence and preserves every option in source order")
        let laterWithDuplicates = CtripFlightParser.displayOrder("## 选择建议\n综合推荐：MF6002，衔接更方便。", representedBy: duplicateSources)
        expect(laterWithDuplicates == duplicateSources, "Provider advice leaves equal-key source order intact even when legacy IDs collide")
        expect(CtripFlightParser.narrative(liveGroupReply, representedBy: liveGroupCards) == liveGroupNarrative, "The compact recommendation helper does not alter the original lossless narrative contract")
        expect(liveGroupCards[10].cardSegments.map(\.title) == ["第一段", "第二段"] && Set(liveGroupCards[10].cardSegments.map(\.id)).count == 2, "Directly displayed segment rows have stable separate identities and source-order labels")
        expect(!liveGroupCards[10].cardSupplement.contains("第一段") && !liveGroupCards[10].cardSupplement.contains("第二段") && liveGroupCards[10].cardSupplement.contains("标签"), "More information no longer duplicates segment text that is already directly visible on the large card")
        expect(connectingCards[0].cardSegments.isEmpty && connectingCards[0].cardSupplement.contains("中转行程"), "Older combined-itinerary source fields remain available without manufacturing separate leg rows")
        var mismatchedSegments = liveGroupCards[10]; mismatchedSegments.title = "CA1234 + CA5678"
        expect(mismatchedSegments.cardSegments.isEmpty && mismatchedSegments.cardSupplement.contains("第一段"), "Unbound segment identities stay in source details instead of masquerading as verified visible leg rows")
        let knownCommonPolicy = "## 行李与退改说明\n免费托运行李20公斤，退改以所选舱位政策为准。"
        expect(CtripFlightParser.commonNotes(knownCommonPolicy, representedBy: liveGroupCards).contains("托运行李20公斤"), "A substantive source-wide allowance is preserved in shared notes rather than erased as flight metadata")

        // Round two: independent deterministic-policy and structured-leg checks.
        func policyOffer(_ code: String, departure: String = "07:00", arrival: String = "10:00", duration: String = "3小时", price: String = "900元（含税）", kind: String = "直飞", query: String = "test", date: String = "2026-10-26", origin: String = "北京首都国际机场T3", destination: String = "深圳宝安国际机场T3", cabin: String = "经济舱", passengers: String = "1位成人", extra: String = "") -> CtripFlightOffer {
            let details = [("中转次数", kind == "中转" ? "1" : ""), ("出发日期", date), ("出发时间", departure), ("到达时间", arrival), ("总耗时", duration), ("价格", price), ("航程类型", kind), ("出发机场", origin), ("到达机场", destination), ("舱位", cabin), ("乘客", passengers)].filter { !$0.1.isEmpty }.map { $0.0 + "：" + $0.1 }.joined(separator: "\n") + (extra.isEmpty ? "" : "\n" + extra)
            return CtripFlightOffer(id: code, title: code, details: details, price: price, bookingURL: nil, query: query, queriedAt: at.addingTimeInterval(86400))
        }
        func queried(_ cards: [CtripFlightOffer], _ query: String) -> [CtripFlightOffer] { cards.map { var item = $0; item.query = query; return item } }
        func ordered(_ cards: [CtripFlightOffer], _ query: String = "test") -> [String] { CtripFlightParser.displayOrder("provider says anything", representedBy: queried(cards, query)).map(\.title) }
        let slowDirect = policyOffer("MU7001", departure: "08:00", arrival: "11:20", duration: "3小时20分钟", price: "500元（含税）")
        let fastDirect = policyOffer("MU7002", departure: "09:00", arrival: "12:00", price: "700元（含税）")
        let fastTransfer = policyOffer("MU7003 + MU7004", departure: "06:00", arrival: "08:00", duration: "2小时", price: "400元（含税）", kind: "中转")
        let policyCards = [slowDirect, fastTransfer, fastDirect]
        expect(ordered(policyCards) == ["MU7002", "MU7001", "MU7003 + MU7004"], "Default policy compares transfer count before total duration, then price, departure and source position")
        expect(ordered(policyCards, "便宜优先，其次最快") == ["MU7003 + MU7004", "MU7001", "MU7002"], "Explicit cheap-first preference overrides default fewer-transfers priority")
        expect(ordered(policyCards, "最快，便宜优先").first == "MU7003 + MU7004", "Explicit user priority order is preserved instead of hard-coding directness first")
        expect(ordered(policyCards, "早到优先").first == "MU7003 + MU7004", "Explicit early-arrival priority uses source calendar date plus arrival time")
        expect(ordered(policyCards, "尽早出发").first == "MU7003 + MU7004", "Explicit early-departure priority supersedes default transfer count")
        expect(ordered(policyCards, "优先直飞，最快").first == "MU7002", "Explicit direct-first preference is a sort preference rather than a fabricated source recommendation")
        let sameExpensive = policyOffer("CA7001", price: "900元（含税）")
        let sameCheap = policyOffer("CA7002", price: "600元（含税）")
        expect(ordered([sameExpensive, sameCheap]) == ["CA7002", "CA7001"], "Equal leading keys compare amounts only when currency, tax and one-passenger basis are all known equal")
        let earlyIncluded = policyOffer("CA7003", departure: "06:00", arrival: "09:00", price: "1000元（含税）")
        let lateExcluded = policyOffer("CA7004", departure: "08:00", arrival: "11:00", price: "400元（不含税费）")
        let mixedTax = queried([lateExcluded, earlyIncluded], "便宜优先")
        expect(CtripFlightParser.displayOrder("", representedBy: mixedTax).first?.title == "CA7003", "Mixed included/excluded tax amounts are skipped for the whole equal-prefix group, continuing to departure time")
        expect(CtripFlightParser.recommendation("", representedBy: mixedTax).commonNotes.contains("未按金额排序"), "The common data-boundary note explicitly discloses mixed or unknown quotation bases independently of sorting-description visibility")
        let usdLate = policyOffer("CA7005", departure: "08:00", arrival: "11:00", price: "100USD（含税）")
        expect(ordered([usdLate, earlyIncluded], "便宜优先").first == "CA7003", "Different currencies are never sorted by their bare numeric amounts")
        let unknownTax = policyOffer("CA7006", departure: "08:00", arrival: "11:00", price: "300元")
        expect(ordered([unknownTax, earlyIncluded], "便宜优先").first == "CA7003", "Unknown tax scope disables amount comparison for the entire group")
        let noBasis = policyOffer("CA7007", departure: "08:00", arrival: "11:00", price: "100元（含税）", passengers: "")
        expect(ordered([noBasis, earlyIncluded], "便宜优先").first == "CA7003", "An unspecified per-person versus total-price basis cannot silently win on its amount")
        let noDuration = policyOffer("CA7008", arrival: "", duration: "", price: "1元（含税）")
        expect(ordered([noDuration, sameExpensive]).last == "CA7008", "Unknown total duration follows a known duration, even when its fare is lower")
        let missingPrice = policyOffer("CA7009", price: "待核实")
        expect(missingPrice.selectionStatus == .insufficientInformation && ordered([missingPrice, sameExpensive]).last == "CA7009", "Unknown actual fare is an information gap and follows an available quote")
        let unknownKind = policyOffer("CA7010", kind: "")
        expect(ordered([unknownKind, fastTransfer, sameExpensive], "直飞优先") == ["CA7001", "MU7003 + MU7004", "CA7010"], "Unknown directness follows explicitly known direct and connecting categories")
        let required = "2026-10-26北京到深圳，1位成人经济舱，只要直飞，06:00-09:00出发，12:00前到达，含税预算不超过1000元"
        let satisfies = policyOffer("HU7001", query: required)
        expect(satisfies.selectionStatus == .satisfied && satisfies.selectionIssues.isEmpty, "Every explicit date, route, passenger, cabin, departure-window, arrival-deadline, directness and inclusive-budget condition is confirmed")
        expect(policyOffer("HU7002", query: required, date: "2026-10-27").selectionStatus == .doesNotMeet, "A wrong departure date is a hard violation")
        expect(policyOffer("HU7003", query: required, date: "").selectionStatus == .insufficientInformation, "A missing source date cannot borrow the user-requested date to claim satisfaction")
        expect(policyOffer("HU7004", query: required, origin: "上海浦东国际机场").selectionStatus == .doesNotMeet, "An explicit departure-city mismatch is a hard violation")
        expect(policyOffer("HU7005", query: required, destination: "广州白云国际机场").selectionStatus == .doesNotMeet, "An explicit destination-city mismatch is a hard violation")
        expect(policyOffer("HU7006", query: required, origin: "").selectionStatus == .insufficientInformation, "Missing endpoint airport information stays unconfirmed")
        expect(policyOffer("HU7007", query: "PEK-SZX，只要直飞").selectionStatus == .satisfied, "Explicit common IATA endpoints match their source airport names without inferring a flight route")
        expect(policyOffer("HU7008", query: required, passengers: "2位成人").selectionStatus == .doesNotMeet, "A different explicit adult count violates a one-adult request")
        expect(policyOffer("HU7009", query: required, passengers: "").selectionStatus == .insufficientInformation, "Passenger count is not silently defaulted when the request explicitly supplies it")
        expect(policyOffer("HU7010", query: required, cabin: "商务舱").selectionStatus == .doesNotMeet, "An explicit cabin mismatch violates the requested cabin")
        expect(policyOffer("HU7011", query: required, cabin: "").selectionStatus == .insufficientInformation, "A requested cabin remains unconfirmed when the source omits it")
        expect(policyOffer("HU7012", departure: "10:00", arrival: "11:00", duration: "1小时", query: required).selectionStatus == .doesNotMeet, "A departure outside the user's explicit clock interval violates the request")
        expect(policyOffer("HU7013", departure: "08:00", arrival: "13:00", duration: "5小时", query: required).selectionStatus == .doesNotMeet, "An arrival after the explicit deadline cannot be preferred")
        expect(policyOffer("HU7014", query: "2026-10-26北京到深圳，最晚09:30到达").selectionStatus == .doesNotMeet, "The alternate latest-arrival phrase is also treated as a hard deadline")
        expect(policyOffer("HU7015", arrival: "次日01:00", duration: "18小时", query: "2026-10-26北京到深圳，12:00前到达").selectionStatus == .doesNotMeet, "A next-day arrival cannot meet a same-departure-day clock deadline merely because its clock is earlier")
        expect(policyOffer("HU7016", arrival: "次日01:00", duration: "18小时", query: "2026-10-26北京到深圳，次日02:00前到达").selectionStatus == .satisfied, "An explicitly next-day arrival deadline uses the requested next calendar day")
        expect(policyOffer("HU7017 + HU7018", kind: "中转", query: required).selectionStatus == .doesNotMeet, "A connecting itinerary violates direct-only, even if the provider calls it recommended")
        expect(policyOffer("HU7019", kind: "经停", query: required).selectionStatus == .doesNotMeet, "An explicitly stopping flight is not treated as non-stop under a direct-only request")
        expect(policyOffer("HU7020", kind: "", query: required).selectionStatus == .insufficientInformation, "A single flight code alone does not establish non-stop eligibility")
        expect(policyOffer("HU7021", price: "1100元（含税）", query: required).selectionStatus == .doesNotMeet, "A same-basis inclusive total above the budget is rejected")
        expect(policyOffer("HU7022", price: "900元（不含税费）", query: required).selectionStatus == .insufficientInformation, "A below-budget fare excluding taxes does not establish an inclusive budget match")
        expect(policyOffer("HU7023", price: "1100元（不含税费）", query: required).selectionStatus == .doesNotMeet, "A fare already exceeding the inclusive budget before tax is a definite violation")
        expect(policyOffer("HU7024", price: "900元（不含税费）", query: "票面预算不超过1000元").selectionStatus == .satisfied, "An explicitly pre-tax fare budget compares only to a known pre-tax amount")
        expect(policyOffer("HU7025", price: "100USD（含税）", query: "含税预算不超过1000元").selectionStatus == .insufficientInformation, "A different source currency cannot be implicitly converted to satisfy a budget")
        expect(policyOffer("HU7026", price: "500元每人（含税）", query: "2位成人经济舱，含税预算不超过800元", passengers: "2位成人").selectionStatus == .insufficientInformation, "A two-person request cannot compare an unconverted per-person quote to a total budget")
        expect(policyOffer("HU7027", price: "800元（含税）总价", query: "2位成人经济舱，含税总预算不超过1000元", passengers: "2位成人").selectionStatus == .satisfied, "An explicit two-person total may satisfy a matching total budget")
        expect(policyOffer("HU7028", query: "明天北京到深圳").selectionStatus == .satisfied, "Relative requested dates are anchored to the stored query timestamp, never to the current display date")
        expect(policyOffer("HU7029", arrival: "", query: "上午到达深圳").selectionStatus == .insufficientInformation, "A requested arrival period with a missing clock remains unknown")
        expect(policyOffer("HU7030", query: "只要直飞，中转也可以").selectionStatus == .insufficientInformation, "Contradictory direct-only and connecting-allowed conditions require clarification instead of choosing one")
        let badSourceDate = policyOffer("HU7031", query: "2026-10-26北京到深圳", extra: "出发日期：2026-10-27")
        expect(badSourceDate.selectionStatus == .insufficientInformation && badSourceDate.selectionIssues.contains(where: { $0.contains("出发日期") }), "Conflicting explicit source dates are not resolved by taking whichever field appeared first")
        expect(policyOffer("HU7032", query: "上午出发", extra: "出发时间：18:00").selectionStatus == .insufficientInformation, "Conflicting explicit source departure clocks do not certify a time window")
        let badQuote = policyOffer("HU7033", arrival: "2026-10-25 10:00")
        expect(badQuote.selectionStatus == .satisfied, "Without a source timezone relationship, reversed local endpoint dates alone do not prove an internal chronology violation")
        let allUnknown = [policyOffer("HU7034", query: required, date: ""), policyOffer("HU7035", query: required, origin: "")]
        expect(CtripFlightParser.recommendation("综合推荐HU7034", representedBy: allUnknown).preferredOfferID == nil, "No option with unconfirmed hard conditions is promoted when every option is incomplete")
        let violated = policyOffer("HU7036", price: "1元（含税）", query: required, date: "2026-10-27")
        let uncertain = policyOffer("HU7037", price: "2元（含税）", query: required, date: "")
        expect(CtripFlightParser.displayOrder("推荐HU7036", representedBy: [violated, uncertain, satisfies]).map(\.id) == [satisfies.id, uncertain.id, violated.id], "All sorting priorities remain subordinate to satisfied, unknown, then violating hard-condition groups")
        let sameLegacyIDs = [slowDirect, fastTransfer, fastDirect].map { item -> CtripFlightOffer in var copy = item; copy.id = "collision"; return copy }
        expect(CtripFlightParser.displayOrder("", representedBy: sameLegacyIDs).map(\.title) == ["MU7002", "MU7001", "MU7003 + MU7004"], "Sorting preserves every distinct itinerary even when all persisted IDs collide")
        expect(CtripFlightParser.displayOrder("", representedBy: CtripFlightParser.displayOrder("", representedBy: sameLegacyIDs)).map(\.title) == ["MU7002", "MU7001", "MU7003 + MU7004"], "Full ordering with duplicate IDs remains idempotent")
        let mixedSet = [sameCheap, lateExcluded, usdLate, earlyIncluded, unknownTax, noBasis, sameExpensive].enumerated().map { index, source -> CtripFlightOffer in
            var copy = source
            copy.details = copy.details.replacingOccurrences(of: "出发时间：" + source.leg(departure: true).time, with: String(format: "出发时间：%02d:00", index + 1))
            return copy
        }
        let orders = [mixedSet, Array(mixedSet.reversed()), Array(mixedSet.dropFirst()) + [mixedSet[0]]].map { ordered($0, "便宜优先") }
        expect(orders.allSatisfy { $0 == orders[0] }, "Mixed-comparison cohorts produce a deterministic transitive order across permutations when all fallback keys are distinct")
        let permutation = [fastTransfer, fastDirect, slowDirect]
        expect(ordered(permutation) == ordered(policyCards), "Non-tied scalar policy keys give the same complete order regardless of provider source order")
        let liveOrdered = CtripFlightParser.displayOrder(liveGroupReply, representedBy: liveGroupCards)
        expect(liveOrdered.count == 16 && liveOrdered[0].cardTitle.contains("MU6671") && liveOrdered[1].cardTitle.contains("MU6667"), "The unchanged actual sixteen-option response replays with the precise default transfer/duration order")
        expect(CtripFlightParser.displayOrder("", representedBy: queried(liveGroupCards, "2026-10-26北京到深圳，1位成人经济舱，便宜优先")).first?.title.contains("ZH9151") == true, "The same actual full response ranks its quoted 400-yuan connecting itinerary first only when the user explicitly prioritizes price")
        expect(liveGroupCards.allSatisfy { $0.selectionStatus == .satisfied }, "All sixteen actual options have matching explicit source date, endpoint cities and available whole-itinerary fares")
        expect(liveGroupCards[10].itinerarySegments.map(\.code) == ["ZH9151", "ZH8934"], "Actual connecting legs expose typed source flight codes inside one itinerary")
        let actualSegments = liveGroupCards[10].itinerarySegments
        expect(actualSegments[0].departure == .init(time: "07:55", airport: "北京首都T3", date: "2026-10-26") && actualSegments[0].arrival == .init(time: "10:00", airport: "襄阳刘集T2", date: "2026-10-26"), "The first typed segment contains its own source date, clocks and both airports")
        expect(actualSegments[1].departure.date == "2026-10-26" && actualSegments[1].arrival.date == "2026-10-27" && actualSegments[1].arrival.time == "01:10", "The second typed segment preserves explicit next-day arrival without guessing a day from the clock")
        expect(actualSegments[0].aircraft == "波音737" && actualSegments[0].duration == "约2小时05分钟" && actualSegments[0].sourceText == liveGroupCards[10].cardSegments[0].text, "Typed segment aircraft, duration and verbatim source all remain inspectable")
        expect(noDateCards[0].itinerarySegments[0].departure.date.isEmpty && noDateCards[0].itinerarySegments[1].arrival.date == "次日", "Typed undated legs preserve only the explicit relative date and do not borrow a date from the user query")
        expect(CtripFlightParser.offers(noNextDay, query: "test", at: at)[0].itinerarySegments[1].arrival.date.isEmpty, "An unmarked midnight wrap stays an unknown segment arrival date")
        let threeDaySource = """
        来源：携程官方查询
        已为您查询到2026年10月26日北京至深圳单程机票（1位成人、经济舱）。
        ### 国航中转方案
        - 第一段：CA7101，23:00 北京首都T3 → 次日01:00 郑州新郑T2，波音737，2小时
        - 第二段：CA7102，次日06:00 郑州新郑T2 → 次日08:00 武汉天河T3，空客320，2小时
        - 第三段：CA7103，后天06:00 武汉天河T3 → 后天08:00 深圳宝安T3，空客320，2小时
        - 参考价：900元（含税）
        - 总耗时：33小时
        """
        let threeDayCards = CtripFlightParser.offers(threeDaySource, query: "2026-10-26北京到深圳", at: at)
        expect(threeDayCards.count == 1 && threeDayCards[0].itinerarySegments.count == 3, "A complete explicitly dated three-segment itinerary is one card with three typed segments")
        expect(threeDayCards[0].itinerarySegments[1].departure.date == "2026-10-27" && threeDayCards[0].itinerarySegments[1].arrival.date == "2026-10-27" && threeDayCards[0].itinerarySegments[2].arrival.date == "2026-10-28", "Repeated next-day qualifiers share the source base date and explicit the-day-after-tomorrow reaches its stated calendar day")
        expect(threeDayCards[0].leg(departure: false).date == "2026-10-28", "The whole-itinerary endpoint agrees with the last structured segment across multiple source-stated days")
        let alternateNextDay = CtripFlightParser.offers(transferOnly.replacingOccurrences(of: "次日01:10", with: "隔天01:10"), query: "test", at: at)
        expect(alternateNextDay[0].itinerarySegments[1].arrival.date == "2026-10-27", "An explicit following-day synonym is resolved from the source date")
        let unmarkedThirdDay = threeDaySource.replacingOccurrences(of: "后天06:00", with: "06:00").replacingOccurrences(of: "后天08:00", with: "08:00")
        let unmarkedThird = CtripFlightParser.offers(unmarkedThirdDay, query: "test", at: at)[0].itinerarySegments[2]
        expect(unmarkedThird.departure.date.isEmpty && unmarkedThird.arrival.date.isEmpty, "A later leg that moves backwards without a date marker does not invent an extra day")
        expect(connectingCards[0].itinerarySegments.isEmpty && connectingCards[0].cardSupplement.contains("中转行程"), "Legacy unsegmented itineraries retain their original fallback without manufactured structured legs")
        expect(mismatchedSegments.itinerarySegments.isEmpty, "Typed segment codes must match the complete offered itinerary identity")
        let newSearch = CtripFlightSearchContext.latest(in: [.init(role: "assistant", text: liveGroupReply, createdAt: at, flightOffers: liveGroupCards, flightQuery: "2026-10-26北京到深圳，直飞和中转")])!
        expect(newSearch.offers.map(\.title) == liveOrdered.map(\.title), "The latest search ordinal set and UI display order are exactly identical under the new full sorting policy")
        expect(CtripFlightParser.displayOrder("", representedBy: boundedCards).count == 30, "Deterministic sorting has no card-count or UI-pagination limit")
        expect(CtripFlightParser.narrative(liveGroupReply, representedBy: liveGroupCards) == liveGroupNarrative, "Policy sorting and typed legs never rewrite raw source or change the lossless narrative contract")

        expect(policyOffer("CZ7201", query: "10月26日北京到深圳").selectionStatus == .satisfied, "A month/day request uses the stored query's calendar year as a requirement without filling source dates")
        expect(policyOffer("CZ7202", query: "预算1000").selectionStatus == .insufficientInformation, "A currency-free numeric budget is unconfirmed rather than silently becoming a CNY total")
        expect(policyOffer("CZ7203", price: "800元（含税）总价", query: "2位成人经济舱，预算不超过1000元", passengers: "2位成人").selectionStatus == .insufficientInformation, "A multi-person budget without explicit per-person or total scope is not assumed to be a group total")
        expect(policyOffer("CZ7204", price: "500元每人（含税）", query: "2位成人经济舱，每人含税预算不超过600元", passengers: "2位成人").selectionStatus == .satisfied, "An explicit per-person budget may compare a known per-person quote")
        expect(policyOffer("CZ7205", query: "北京到深圳，只要800元以内的含税机票").selectionStatus == .doesNotMeet, "An explicit amount followed by a within-limit phrase is a budget cap even without the budget noun")
        expect(policyOffer("CZ7206 + CZ7207", kind: "中转", query: "不只直飞，中转也可以").selectionStatus == .satisfied, "A negated direct-only phrase does not ban explicitly allowed connecting options")
        let stopoverOnly = queried([liveGroupCards[13]], "2026-10-26北京到深圳，只要直飞")
        expect(stopoverOnly[0].selectionStatus == .doesNotMeet && CtripFlightParser.recommendation("推荐DZ6210", representedBy: stopoverOnly).preferredOfferID == nil, "The actual explicitly stopping DZ6210 is rejected for direct-only and cannot become preferred")
        let ambiguousPrice = policyOffer("CZ7208", extra: "价格：100元（含税）")
        expect(ambiguousPrice.selectionStatus == .insufficientInformation, "Conflicting whole-itinerary price fields cannot be silently certified by choosing the first one")
        expect(CtripFlightParser.recommendation("兼顾价格与效率，首选MU7001", representedBy: policyCards).advice.isEmpty, "No generic provider reason is surfaced as decision advice")
        let conciseSort = CtripFlightParser.recommendation("", representedBy: policyCards).sortDescription
        expect(conciseSort == "排序：中转次数少 → 总耗时短 → 同口径报价低 → 起飞早。", "The normal user-facing sorting summary contains only the concrete comparison order")

        let firstRelativeSource = threeDaySource.replacingOccurrences(of: "CA7101，23:00", with: "CA7101，次日00:00")
        let firstRelative = CtripFlightParser.offers(firstRelativeSource, query: "2026-10-26北京到深圳", at: at)[0]
        expect(firstRelative.itinerarySegments[0].departure.date == "2026-10-27" && firstRelative.leg(departure: true).date == "2026-10-27", "An explicit relative date on the first leg reaches the same actual date in the whole-card endpoint and typed segment")
        expect(firstRelative.selectionStatus == .doesNotMeet, "An explicit next-day first departure cannot satisfy the source-query day's departure requirement")
        expect(policyOffer("CZ7209", arrival: "后天10:00", duration: "51小时").leg(departure: false).date == "2026-10-28", "An explicit two-day relative arrival is preserved for a legacy whole-flight endpoint as well")

        let twoAdultTotal = policyOffer("CA7301", departure: "09:00", arrival: "12:00", price: "900元（不含税费）总价", query: "2位成人经济舱，便宜优先", passengers: "2位成人")
        let adultUnitOnly = policyOffer("MU7301", departure: "08:00", arrival: "11:00", price: "500元每成人（不含税费）", query: "2位成人经济舱，便宜优先", passengers: "")
        let partyUnspecified = policyOffer("ZH7301", departure: "07:00", arrival: "10:00", price: "700元（不含税费）", query: "2位成人经济舱，便宜优先", passengers: "")
        expect(twoAdultTotal.selectionStatus == .satisfied && adultUnitOnly.selectionStatus == .insufficientInformation && partyUnspecified.selectionStatus == .insufficientInformation, "A per-adult amount never certifies applicability to two adults without a source-stated matching party")
        expect(CtripFlightParser.displayOrder("推荐MU7301", representedBy: [partyUnspecified, adultUnitOnly, twoAdultTotal]).map(\.title) == ["CA7301", "ZH7301", "MU7301"], "Confirmed two-adult applicability outranks cheaper-looking or earlier incomplete party quotes before price preferences")
        let airportConflictSource = transferOnly.replacingOccurrences(of: "- **第一段**", with: "- 出发机场：北京首都机场T3\n- **第一段**").replacingOccurrences(of: "07:55 北京首都T3", with: "07:55 北京大兴机场")
        let conflictingAirport = CtripFlightParser.offers(airportConflictSource, query: "2026-10-26从北京首都机场T3到深圳", at: at)[0]
        expect(conflictingAirport.itinerarySegments[0].departure.airport == "北京大兴机场" && conflictingAirport.selectionStatus == .insufficientInformation, "Top-level Capital T3 and first-segment Daxing conflict cannot certify an exact Capital-airport departure condition")
        var cityOnlyConflict = conflictingAirport; cityOnlyConflict.query = "2026-10-26北京到深圳"
        expect(cityOnlyConflict.selectionStatus == .satisfied, "Both conflicting departure-airport variants may still establish the same requested city without asserting either exact airport")
        let oldOneCode = policyOffer("CA7302", kind: "")
        expect(ordered([oldOneCode, fastTransfer]).first == fastTransfer.title, "One flight code does not establish zero aircraft transfers; unknown count follows a source-stated connecting count")
        let stopped = liveGroupCards[13]
        expect(CtripFlightParser.displayOrder("", representedBy: [stopped, liveGroupCards[10]]).first?.id == liveGroupCards[10].id, "A stopover's single flight code does not prove zero transfers; the complete two-leg itinerary has a known count and sorts before unknown")
        var explicitStopped = stopped; explicitStopped.details += "\n换乘次数：0"
        expect(CtripFlightParser.displayOrder("", representedBy: [liveGroupCards[10], explicitStopped]).first?.id == explicitStopped.id, "An explicit source statement of zero transfers may establish the count for a stopover, while it still remains non-direct")
        expect(liveOrdered.first?.id == liveGroupCards[3].id && CtripFlightParser.displayOrder("", representedBy: liveGroupCards).last?.id == liveGroupCards[13].id, "The unchanged actual reply retains the fastest direct first and puts the unconfirmed stopover transfer count after all known connecting counts")

        let websiteBoundary = """
        来源：携程官方查询
        ### CA7401
        日期：2026-10-26
        出发时间：07:00
        到达时间：10:00
        参考价：900元（含税）
        来源：其他网站
        ### ZZ7402
        日期：2026-10-26
        出发时间：08:00
        到达时间：11:00
        参考价：100元（含税）
        预订链接：https://flights.ctrip.com/booking/detail?flightNo=ZZ7402
        来源：携程官方查询
        ### MU7403
        日期：2026-10-26
        出发时间：09:00
        到达时间：12:00
        参考价：800元（含税）
        """
        let websiteCards = CtripFlightParser.offers(websiteBoundary, query: "test", at: at)
        expect(websiteCards.count == 3 && websiteCards.map(\.isSchedule) == [false, true, false], "An explicit other-website source marker separates the external reference from both independently bounded official fare blocks")
        expect(websiteCards[1].cardPrice == "票价待查" && websiteCards[1].bookingURL == nil && websiteCards[1].selectionStatus == .insufficientInformation, "External source times may survive as reference data but its amount and official-looking booking URL cannot become a quoted offer")
        expect(websiteCards[0].cardPrice == "900元 · 含税" && websiteCards[2].cardPrice == "800元 · 含税", "An external source span does not invalidate already independent official blocks or prevent an explicit return to official sourcing")
        expect(CtripFlightParser.recommendation("", representedBy: [websiteCards[1]]).preferredOfferID == nil, "An external timetable reference cannot be preferred as a qualifying fare")
        let ordinaryWebsiteText = websiteBoundary.replacingOccurrences(of: "来源：其他网站", with: "请在其他网站查看帮助说明。")
        expect(CtripFlightParser.offers(ordinaryWebsiteText, query: "test", at: at).allSatisfy { !$0.isSchedule }, "The ordinary website noun in body text does not switch source scope")
        let quotedSourceText = websiteBoundary.replacingOccurrences(of: "来源：其他网站", with: "“来源：其他网站”只是示例按钮文字。")
        expect(CtripFlightParser.offers(quotedSourceText, query: "test", at: at).allSatisfy { !$0.isSchedule }, "A quoted source-label example in prose does not act as a source boundary")
        let negatedWebsiteText = websiteBoundary.replacingOccurrences(of: "来源：其他网站", with: "来源：并非其他网站，仍为携程官方查询")
        expect(CtripFlightParser.offers(negatedWebsiteText, query: "test", at: at).allSatisfy { !$0.isSchedule }, "An explicit denial of the other-website source is not mistaken for an affirmative source marker")
        let headingWebsiteText = websiteBoundary.replacingOccurrences(of: "来源：其他网站", with: "## 来源：第三方网站（仅时刻）")
        expect(CtripFlightParser.offers(headingWebsiteText, query: "test", at: at).map(\.isSchedule) == [false, true, false], "A Markdown source heading with an explicit third-party website label preserves the same source boundary")
        let websiteNotNetwork = websiteBoundary.replacingOccurrences(of: "来源：其他网站", with: "来源：其它网站，并非网络来源")
        expect(CtripFlightParser.offers(websiteNotNetwork, query: "test", at: at).map(\.isSchedule) == [false, true, false], "A denial of network sourcing does not cancel a separate affirmative other-website source declaration")
        expect(CtripFlightParser.legacyFallbackOffers(websiteCards, in: websiteBoundary).map(\.title) == [websiteCards[0].title, websiteCards[2].title], "The same explicit external-source span filters only its identified legacy candidates, preserving independent official identities")

        let excludePriceQuery = "不要按价格排序，优先直飞"
        let excludedPriceCards = queried(policyCards, excludePriceQuery)
        let excludedPriceDecision = CtripFlightParser.recommendation("", representedBy: excludedPriceCards)
        expect(CtripFlightParser.displayOrder("", representedBy: excludedPriceCards).first?.id == fastDirect.id && !excludedPriceDecision.sortDescription.contains("报价低"), "An explicit ban on sorting by price removes the price key entirely rather than promoting the negated phrase")
        let sameLateCheap = policyOffer("CA7601", departure: "08:00", arrival: "11:00", price: "100元（含税）")
        expect(ordered([sameLateCheap, earlyIncluded], excludePriceQuery).first == earlyIncluded.title, "Completely excluded price does not return as a hidden default tie-breaker before departure time")
        let notPrimaryPrice = queried(policyCards, "不要低价优先，最快优先")
        let notPrimaryDecision = CtripFlightParser.recommendation("", representedBy: notPrimaryPrice)
        expect(CtripFlightParser.displayOrder("", representedBy: notPrimaryPrice).first?.id == fastTransfer.id, "Negating cheap-first removes that primary preference and honors an explicit fastest-first request")
        expect(notPrimaryDecision.sortDescription.hasPrefix("排序：总耗时短") && notPrimaryDecision.sortDescription.contains("同口径报价低"), "Canceling price as the primary priority still permits its ordinary later default tie-breaker")
        let laterPrice = CtripFlightParser.recommendation("", representedBy: queried(policyCards, "不要低价优先，最快优先，其次价格优先"))
        expect(laterPrice.sortDescription.hasPrefix("排序：总耗时短 → 同口径报价低"), "A later positive price preference can be recognized after an earlier negated occurrence without losing its stated priority position")
        let cancelledFastest = CtripFlightParser.recommendation("", representedBy: queried(policyCards, "不要最快优先，直飞优先"))
        expect(cancelledFastest.sortDescription.hasPrefix("排序：直飞优先 → 中转次数少 → 总耗时短"), "Negation filtering also prevents another negated priority phrase from displacing the following positive preference")
        expect(CtripFlightParser.recommendation("", representedBy: queried(policyCards, "不是低价优先，优先直飞")).sortDescription.hasPrefix("排序：直飞优先"), "The explicit not-cheap-first wording is not mistaken for a positive cheap-first request")
        let morningSoft = policyOffer("CA7602", departure: "07:00", arrival: "10:00", price: "900元（含税）")
        let afternoonSoft = policyOffer("MU7603", departure: "13:00", arrival: "15:00", duration: "2小时", price: "600元（含税）")
        let eveningSoft = policyOffer("ZH7604", departure: "19:00", arrival: "20:00", duration: "1小时", price: "300元（含税）")
        let softPeriods = queried([afternoonSoft, eveningSoft, morningSoft], "最好上午出发，也可以下午")
        expect(softPeriods.allSatisfy { $0.selectionStatus == .satisfied && $0.selectionIssues.isEmpty && $0.cardWarnings.isEmpty }, "Preferred morning plus acceptable afternoon creates no contradictory hard windows or legacy mismatch warnings")
        expect(CtripFlightParser.displayOrder("", representedBy: softPeriods).map(\.id) == [morningSoft.id, afternoonSoft.id, eveningSoft.id], "A typed soft departure-period key ranks explicit morning preference, accepted afternoon fallback, then other periods")
        expect(CtripFlightParser.recommendation("", representedBy: softPeriods).sortDescription.hasPrefix("排序：上午出发优先"), "The concise description names the user's actual soft period preference")
        let alternativeWording = queried([afternoonSoft, morningSoft], "优先上午，下午也可以")
        expect(alternativeWording.allSatisfy { $0.selectionStatus == .satisfied && $0.cardWarnings.isEmpty } && CtripFlightParser.displayOrder("", representedBy: alternativeWording).first?.id == morningSoft.id, "Morning-priority and afternoon-also-acceptable wording stays soft and preserves its explicit ranking")
        expect(ordered([eveningSoft, afternoonSoft], "最好上午出发，也可以下午").first == afternoonSoft.title, "When the preferred morning is absent, the explicitly accepted afternoon ranks ahead of an unspecified evening")
        let noClockSoft = policyOffer("CA7605", departure: "", query: "最好上午出发，也可以下午")
        expect(noClockSoft.selectionStatus == .satisfied && CtripFlightParser.displayOrder("", representedBy: [noClockSoft] + softPeriods).last?.id == noClockSoft.id, "An unknown soft-period clock is not a hard violation and sorts after known period scores")
        let strictMorning = queried([morningSoft, afternoonSoft], "必须上午出发")
        expect(strictMorning[0].selectionStatus == .satisfied && strictMorning[1].selectionStatus == .doesNotMeet && !strictMorning[1].cardWarnings.isEmpty, "An explicitly hard morning window remains a hard condition after introducing soft preferences")
        let softWithDeadline = queried([morningSoft, afternoonSoft], "最好上午出发，也可以下午，但12:00前到达")
        expect(softWithDeadline[0].selectionStatus == .satisfied && softWithDeadline[1].selectionStatus == .doesNotMeet, "A real arrival deadline remains binding even when the separate departure period is soft")
        let softArrival = queried([afternoonSoft, morningSoft], "最好上午到达，下午也可以")
        expect(softArrival.allSatisfy { $0.selectionStatus == .satisfied && $0.cardWarnings.isEmpty } && CtripFlightParser.displayOrder("", representedBy: softArrival).first?.id == morningSoft.id, "Soft arrival-period preferences use arrival clocks and propagate the stated arrival role to an abbreviated fallback clause")
        expect(CtripFlightParser.recommendation("", representedBy: softArrival).sortDescription.hasPrefix("排序：上午到达优先"), "Soft arrival and departure preferences remain distinct typed sort keys")
        expect(ordered([morningSoft, afternoonSoft], "便宜优先，最好上午出发，也可以下午").first == afternoonSoft.title, "An earlier explicit price priority remains ahead of a later soft morning preference")
        expect(ordered([morningSoft, afternoonSoft], "最好上午出发，也可以下午，便宜优先").first == morningSoft.title, "An earlier soft morning preference remains ahead of a later explicit price priority")
        expect(policyOffer("CA7606", arrival: "15:00", duration: "8小时", query: "上午出发，下午到达").selectionStatus == .satisfied, "Hard period roles are scoped to their own clauses instead of bleeding arrival words across punctuation")
        expect(policyOffer("CA7607", query: "上午出发，下午到达").selectionStatus == .doesNotMeet, "Separate hard departure and arrival windows still reject an out-of-window arrival")
        let softContext = CtripFlightSearchContext.latest(in: [.init(role: "assistant", text: "", createdAt: at, flightOffers: softPeriods, flightQuery: "最好上午出发，也可以下午")])!
        expect(softContext.offers.map(\.id) == CtripFlightParser.displayOrder("", representedBy: softPeriods).map(\.id), "Soft preference ordering uses exactly the same ordinal sequence for UI and stored candidate context")
        expect(CtripFlightParser.displayOrder("", representedBy: CtripFlightParser.displayOrder("", representedBy: softPeriods)).map(\.id) == [morningSoft.id, afternoonSoft.id, eveningSoft.id], "The new typed soft-period comparison is deterministic and idempotent")

        let unsupportedCurrencyValues = ["100欧元（含税）", "100日元（含税）", "JPY100（含税）", "100JPY（含税）"]
        expect(unsupportedCurrencyValues.allSatisfy { CtripFlightParser.priceLabel($0) == nil }, "Already unsupported euro and yen amount formats remain rejected instead of being shortened to a yuan amount")
        let ambiguousCurrencyValues = ["100元（JPY，含税）", "100元（欧元，含税）", "100元（GBP，含税）", "USD100元（含税）", "100美元（人民币，含税）"]
        expect(ambiguousCurrencyValues.allSatisfy { CtripFlightParser.priceLabel($0) == nil }, "An explicit unsupported or conflicting source currency annotation cannot be discarded while creating a price label")
        let yuanQuote = policyOffer("CA7801", departure: "06:00", arrival: "09:00", price: "900元（含税）", query: "价格优先")
        for (index, price) in ambiguousCurrencyValues.enumerated() {
            let ambiguous = policyOffer("MU\(7802 + index)", departure: "08:00", arrival: "11:00", price: price, query: "价格优先")
            expect(ambiguous.selectionStatus == .insufficientInformation && ambiguous.cardPrice == "价格待核实" && CtripFlightParser.displayOrder("", representedBy: [ambiguous, yuanQuote]).first?.id == yuanQuote.id, "Ambiguous currency case \(index + 1) remains unquoted and cannot outrank a verified CNY amount on price")
        }
        expect(CtripFlightParser.priceLabel("100元（CNY，含税）") == "100元 · 含税" && CtripFlightParser.priceLabel("100元（人民币，含税）") == "100元 · 含税", "Consistent explicit CNY annotations retain the supported yuan quote")
        expect(CtripFlightParser.priceLabel("USD100（USD，含税）") == "USD100 · 含税" && CtripFlightParser.priceLabel("100美元（USD，含税）") == "100美元 · 含税", "Consistent supported USD code and unit labels remain usable without conversion")
        expect(CtripFlightParser.priceLabel("HKD100（HKD，含税）") == "HKD100 · 含税" && CtripFlightParser.priceLabel("100港元（HKD，含税）") == "100港元 · 含税", "Consistent supported HKD code and unit labels remain usable without conversion")
        expect(CtripFlightParser.displayOrder("", representedBy: [policyOffer("MU7810", departure: "08:00", arrival: "11:00", price: "100元（人民币，含税）", query: "价格优先"), yuanQuote]).first?.id == "MU7810", "A genuinely same-currency and same-basis lower CNY amount still compares numerically")
        var sanitizedLegacyPrice = policyOffer("MU7811", price: "100元（JPY，含税）", query: "价格优先"); sanitizedLegacyPrice.price = "100元 · 含税"
        expect(sanitizedLegacyPrice.cardPrice == "价格待核实" && sanitizedLegacyPrice.selectionStatus == .insufficientInformation, "An old sanitized cached amount cannot conceal a contradictory currency in the authoritative stored price field")

        expect(sanitizedLegacyPrice.cardSupplement.contains("JPY") && sanitizedLegacyPrice.bookingSummary.contains("查询参考价：价格待核实") && !sanitizedLegacyPrice.bookingSummary.contains("100元"), "The visible supplement preserves the original currency conflict while the handoff summary reports an unverified amount, never the stale sanitized CNY number")
        let unsupportedParsedSource = "来源：携程官方查询\n### MU7812\n日期：2026-10-26\n出发时间：08:00\n到达时间：11:00\n参考价：100元（JPY，含税）"
        let unsupportedParsedCards = CtripFlightParser.offers(unsupportedParsedSource, query: "价格优先", at: at)
        expect(unsupportedParsedCards.count == 1 && unsupportedParsedCards[0].isSchedule && unsupportedParsedCards[0].cardPrice == "票价待查" && !unsupportedParsedCards[0].bookingSummary.contains("100元"), "A newly parsed explicit unsupported currency can only produce an unpriced timetable reference, never a sanitized quoted card or handoff amount")

        let crossZoneUnknown = policyOffer("MU7901", departure: "2026-10-26 09:00 UTC+08:00", arrival: "2026-10-26 13:00 UTC+09:00", duration: "", query: "2026-10-26出发，最快优先")
        let explicitLonger = policyOffer("CA7902", departure: "2026-10-26 09:00 UTC+08:00", arrival: "2026-10-26 13:30 UTC+08:00", duration: "4小时30分钟", query: "2026-10-26出发，最快优先")
        expect(CtripFlightParser.displayOrder("", representedBy: [crossZoneUnknown, explicitLonger]).first?.id == explicitLonger.id, "A missing source duration with different endpoint UTC offsets stays unknown instead of becoming a fabricated four-hour local-clock difference")
        expect(CtripFlightParser.value("总耗时", in: crossZoneUnknown.details).isEmpty && !crossZoneUnknown.cardMetadata.contains("4小时"), "No calculated duration is inserted into source metadata or the visible card")
        let unknownZoneClocks = policyOffer("MU7903", departure: "09:00", arrival: "10:00", duration: "", query: "最快优先")
        expect(ordered([unknownZoneClocks, explicitLonger], "最快优先").first == explicitLonger.title, "Even clocks without explicit offsets do not establish a shared timezone or allow duration inference")
        let reverseZoneClock = policyOffer("ZH7904", departure: "2026-10-26 13:00 UTC+09:00", arrival: "2026-10-26 09:30 UTC-04:00", duration: "9小时30分钟", query: "2026-10-26出发，最快优先")
        expect(reverseZoneClock.selectionStatus == .satisfied && !reverseZoneClock.selectionIssues.contains(where: { $0.contains("顺序") || $0.contains("冲突") }), "Reverse displayed clocks across explicitly different UTC offsets are not falsely treated as a global source chronology conflict")
        expect(CtripFlightParser.recommendation("", representedBy: [reverseZoneClock]).preferredOfferID == reverseZoneClock.id, "A quoted option with source-stated total duration may satisfy its hard departure date despite an earlier arrival clock in another timezone")
        var localWindowCheck = crossZoneUnknown; localWindowCheck.query = "2026-10-26出发，上午出发，下午到达"
        expect(localWindowCheck.selectionStatus == .satisfied && localWindowCheck.cardWarnings.isEmpty, "Each endpoint's requested local calendar period is still checked against its own source date and clock without timezone conversion")
        var localDeadlineCheck = crossZoneUnknown; localDeadlineCheck.query = "2026-10-26出发，12:00前到达"
        expect(localDeadlineCheck.selectionStatus == .doesNotMeet, "A source-local arrival after the user's explicit local deadline still violates that deadline")
        let explicitFlightDuration = policyOffer("CA7905", departure: "09:00", arrival: "13:00", duration: "", query: "最快优先", extra: "飞行时长：3小时")
        expect(ordered([explicitLonger, explicitFlightDuration], "最快优先").first == explicitFlightDuration.title, "An explicitly returned single-flight duration remains usable; the restriction only removes inferred endpoint-clock subtraction")
        expect(CtripFlightParser.displayOrder("", representedBy: liveGroupCards).map(\.id) == liveOrdered.map(\.id), "All sixteen actual Beijing-Shenzhen options retain their prior complete order because their total durations were explicitly returned")

        // The complete untouched Build 132 tool-facing assistant response is a
        // portable fixture, including the stale saved sixteen segment cards.
        struct Build132Fixture: Decodable { var message: AssistantMessage }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/build132-fresh-flight-response.json")
        let fixtureBytes = try Data(contentsOf: fixtureURL)
        let fresh132 = try JSONDecoder().decode(Build132Fixture.self, from: fixtureBytes).message
        let fresh132Query = fresh132.flightQuery!
        let fresh132Cards = CtripFlightParser.offers(fresh132.text, query: fresh132Query, at: fresh132.createdAt)
        func codes(_ items: [CtripFlightOffer]) -> [String] { items.map { CtripFlightParser.flightNumbers(in: $0.title).joined(separator: "+") } }
        let expectedSourceCodes = ["DZ6210", "MF8349", "CA8369+CA3696", "ZH1169+ZH9850", "CA8623+CA3640", "ZH1023+ZH9140", "ZH4348+ZH9958", "CA4162+CA3886", "CA1461+CA3886", "ZH9151+ZH8934"]
        expect(fresh132.text.count == 3432 && fresh132.flightOffers?.count == 16, "The new fixture keeps the complete real response and its original faulty sixteen-card cache intact")
        expect(fresh132Cards.count == 10 && fresh132Cards.allSatisfy { !$0.isSchedule }, "The real two-direct plus eight-connecting response rebuilds ten complete quoted itineraries")
        expect(codes(fresh132Cards) == expectedSourceCodes, "Source plan headings and their complete segments produce exactly one identity per itinerary with no duplicated heading codes")
        expect(fresh132Cards.prefix(2).allSatisfy { $0.itinerarySegments.isEmpty } && fresh132Cards.dropFirst(2).allSatisfy { $0.itinerarySegments.count == 2 }, "Direct plans remain direct cards and every connecting plan keeps both typed segments on one card")
        expect(fresh132Cards.map(\.cardPrice) == ["CNY 400 · 不含税", "CNY 660 · 不含税", "CNY 630 · 不含税", "CNY 630 · 不含税", "CNY 520 · 不含税", "CNY 520 · 不含税", "CNY 610 · 不含税", "CNY 610 · 不含税", "CNY 610 · 不含税", "CNY 400 · 不含税"], "The new currency-and-quote label retains every source CNY amount and its pre-tax basis")
        expect(fresh132Cards.allSatisfy { CtripFlightParser.value("价格", in: $0.details).contains("/人") && $0.cardMetadata.contains("1人/单程") }, "Per-person quotation and one-person one-way unit remain available without turning the price into a guessed group total")
        expect(fresh132Cards.allSatisfy { CtripFlightParser.value("乘客", in: $0.details) == "1位成人" && $0.selectionStatus == .satisfied }, "The source introduction's explicit one-adult scope confirms all ten plan party constraints")
        let fresh132Default = CtripFlightParser.displayOrder(fresh132.text, representedBy: fresh132Cards)
        let expectedDefaultCodes = ["MF8349", "DZ6210", "CA8369+CA3696", "ZH1169+ZH9850", "CA8623+CA3640", "ZH1023+ZH9140", "ZH4348+ZH9958", "CA4162+CA3886", "CA1461+CA3886", "ZH9151+ZH8934"]
        expect(codes(fresh132Default) == expectedDefaultCodes && CtripFlightParser.recommendation(fresh132.text, representedBy: fresh132Cards).preferredOfferID == fresh132Cards[1].id, "Default source-based sorting prefers the returned direct MF8349 with 3h40m over the 4h25m direct plan")
        let fresh132Cheap = queried(fresh132Cards, fresh132Query + "，价格优先")
        expect(codes(CtripFlightParser.displayOrder("", representedBy: fresh132Cheap)) == ["DZ6210", "ZH9151+ZH8934", "CA8623+CA3640", "ZH1023+ZH9140", "ZH4348+ZH9958", "CA4162+CA3886", "CA1461+CA3886", "CA8369+CA3696", "ZH1169+ZH9850", "MF8349"], "Explicit cheap-first sorting compares this actual same-CNY same-tax one-adult cohort before default connection and duration tie-breakers")
        expect(fresh132Cards.allSatisfy { $0.leg(departure: true).airport.contains("北京") && $0.leg(departure: false).airport.contains("深圳") }, "Every main card remains the complete source-stated Beijing-Shenzhen journey rather than an isolated intermediate leg")
        expect(fresh132Cards[2].field("出发机场") == "大兴" && fresh132Cards[2].field("到达机场") == "宝安 T3" && fresh132Cards[2].leg(departure: true).airport == "北京 · 大兴", "Raw abbreviated airport fields stay unchanged while only source-stated endpoint cities contextualize their presentation")
        expect(fresh132Cards.dropFirst(2).allSatisfy { $0.itinerarySegments[0].departure.airport.contains("北京") && $0.itinerarySegments[1].arrival.airport.contains("深圳") }, "The first and last segment rows use the same source city context as their whole itinerary without changing intermediate airports")
        let all132Airports = fresh132Cards.flatMap { offer in [offer.leg(departure: true).airport, offer.leg(departure: false).airport] + offer.itinerarySegments.flatMap { [$0.departure.airport, $0.arrival.airport] } }
        expect(all132Airports.allSatisfy { $0.range(of: #"出发|到达|空客|波音|分钟|[（(]"#, options: .regularExpression) == nil }, "Airport labels exclude only source departure/arrival suffixes and complete aircraft metadata, with no leaked parenthesis fragments")
        expect(fresh132Cards[2].itinerarySegments[0].arrival.airport == "南京禄口 T1" && fresh132Cards[2].itinerarySegments[1].departure.airport == "南京禄口 T2", "Different source terminals on either side of a transfer remain distinct")
        expect(fresh132Cards[2].itinerarySegments[0].sourceText == "CA8369，2026-10-26 15:20 大兴出发 → 17:10 南京禄口 T1到达（波音737，110分钟）" && fresh132Cards[2].itinerarySegments[0].aircraft == "波音737" && fresh132Cards[2].itinerarySegments[0].duration == "110分钟", "Each structured segment separately exposes clean endpoint data, source aircraft and duration while retaining the full original segment text")
        expect(fresh132Cards[9].itinerarySegments[1].departure.date == "2026-10-26" && fresh132Cards[9].itinerarySegments[1].arrival.date == "2026-10-27" && fresh132Cards[9].itinerarySegments[1].arrival.time == "01:10", "Plan ten's explicit second-leg departure date and next-day marker anchor the actual 27th arrival")
        expect(fresh132Cards[9].leg(departure: false).date == "2026-10-27" && fresh132Cards[9].leg(departure: false).time == "01:10", "The main itinerary endpoint agrees with the last complete next-day segment")
        expect(fresh132Cards[9].cardMetadata.contains("17小时15分钟") && fresh132Cards[9].cardSupplement.contains("1035分钟") && fresh132Cards[9].cardSupplement.contains("跨日至10月27日"), "The last plan displays its explicit total duration and preserves the longer source duration/cross-day qualification in more information")
        expect(fresh132Cards.allSatisfy { $0.cardSupplement.contains("行李/退改/预订链接：待核实") }, "Every plan retains the source's explicit unresolved baggage, change/refund and booking-link fields")
        expect(fresh132Cards.dropFirst(2).allSatisfy { !$0.cardSupplement.contains("第一段") && !$0.cardSupplement.contains("第二段") && !$0.cardSupplement.contains("第一航段") }, "Source segment details are not repeated in more information when their full text is already shown inside the card")
        let fresh132Narrative = CtripFlightParser.narrative(fresh132.text, representedBy: fresh132Cards)
        expect(!fresh132Narrative.contains("### 方案") && !fresh132Narrative.contains("**第一航段**") && !fresh132Narrative.contains("**币种及报价**"), "Represented actual plan headings, segment lists and quotation fields do not survive as a duplicate narrative list")
        expect(CtripFlightSearchContext.latest(in: [fresh132])?.offers.map(\.id) == fresh132Default.map(\.id), "The original stale sixteen-card archive is rebuilt into the same ten complete UI and follow-up ordinal candidates")
        expect(!fresh132Cards[0].cardMetadata.contains("经停") && CtripFlightParser.recommendation("", representedBy: queried([fresh132Cards[0]], "只要直飞")).preferredOfferID == fresh132Cards[0].id, "This new source explicitly calls DZ6210 direct; no earlier response's stopover fact leaks into the fresh result")
        let firstTransferStart = fresh132.text.range(of: "### 方案3：")!.lowerBound
        let firstTransferEnd = fresh132.text.range(of: "### 方案4：")!.lowerBound
        let first132Transfer = String(fresh132.text[firstTransferStart..<firstTransferEnd])
        let realSourceIntro = String(fresh132.text[..<fresh132.text.range(of: "### 方案1：")!.lowerBound])
        let undatedIntroTransfer = CtripFlightParser.offers("来源：携程官方查询\n" + first132Transfer, query: fresh132Query, at: Date(timeIntervalSince1970: 3_000_000_000))[0]
        expect(CtripFlightParser.value("乘客", in: undatedIntroTransfer.details).isEmpty && CtripFlightParser.value("出发城市", in: undatedIntroTransfer.details).isEmpty && undatedIntroTransfer.selectionStatus == .insufficientInformation, "Without a reliable source introduction, one untyped person and abbreviated airports cannot borrow adult type or cities from the user query")
        expect(undatedIntroTransfer.leg(departure: true).airport == "大兴" && undatedIntroTransfer.leg(departure: false).airport == "宝安 T3" && undatedIntroTransfer.leg(departure: true).date == "2026-10-26", "Missing source city scope leaves airport abbreviations intact while each explicitly dated segment still supplies its own actual departure date")
        let noLocalCabin = (realSourceIntro + first132Transfer).replacingOccurrences(of: "- **舱位**：经济舱（1.3折）", with: "")
        let inherited132Cabin = CtripFlightParser.offers(noLocalCabin, query: fresh132Query, at: fresh132.createdAt)[0]
        expect(CtripFlightParser.value("舱位", in: inherited132Cabin.details) == "经济舱" && inherited132Cabin.selectionStatus == .satisfied, "The source introduction's adjacent adult-and-cabin wording may safely fill an omitted local cabin")
        let localPartyConflict = (realSourceIntro + first132Transfer).replacingOccurrences(of: "1人/单程", with: "2人/单程")
        let conflicting132Party = CtripFlightParser.offers(localPartyConflict, query: fresh132Query, at: fresh132.createdAt)[0]
        expect(conflicting132Party.selectionStatus == .insufficientInformation && conflicting132Party.selectionIssues.contains(where: { $0.contains("计价单位") }) && CtripFlightParser.recommendation("", representedBy: [conflicting132Party]).preferredOfferID == nil, "A local two-person unit contradicting the global one-adult scope stays unconfirmed rather than becoming an eligible one-adult quote")
        expect(queried([fresh132Cards[2]], "2026-10-26北京到深圳，2位成人经济舱")[0].selectionStatus == .doesNotMeet, "Changing the human request to two adults never rewrites the actual one-adult source scope")
        let mismatched132Heading = fresh132.text.replacingOccurrences(of: "### 方案3：CA8369 + CA3696", with: "### 方案3：CA9999 + CA3696")
        expect(CtripFlightParser.offers(mismatched132Heading, query: fresh132Query, at: fresh132.createdAt).count == 9, "A grouped header that contradicts its segment codes is retained in raw text without creating a mismatched or isolated-segment quote")
        let wrong132Count = fresh132.text.replacingOccurrences(of: "### 方案3：CA8369 + CA3696 中转1次", with: "### 方案3：CA8369 + CA3696 中转2次")
        expect(CtripFlightParser.offers(wrong132Count, query: fresh132Query, at: fresh132.createdAt).count == 9, "An explicit connection count inconsistent with the complete source segment set cannot be certified")
        let missing132Leg = fresh132.text.replacingOccurrences(of: "- **第二航段**：CA3696，2026-10-26 19:20 南京禄口 T2出发 → 21:55 宝安 T3到达（空客320，155分钟）", with: "")
        expect(CtripFlightParser.offers(missing132Leg, query: fresh132Query, at: fresh132.createdAt).count == 9, "An incomplete group does not donate its first leg or price to a standalone card or neighboring itinerary")
        let no132Codes = fresh132.text.replacingOccurrences(of: "### 方案3：CA8369 + CA3696 中转1次（中国国际航空，经南京禄口）", with: "### 中国国际航空中转方案（经南京禄口）")
        expect(CtripFlightParser.offers(no132Codes, query: fresh132Query, at: fresh132.createdAt).count == 10, "The new coded heading form remains compatible with the earlier code-free grouped heading form")
        let numeric132Legs = fresh132.text.replacingOccurrences(of: "第一航段", with: "第1航段").replacingOccurrences(of: "第二航段", with: "第2航段")
        expect(CtripFlightParser.offers(numeric132Legs, query: fresh132Query, at: fresh132.createdAt).dropFirst(2).allSatisfy { $0.itinerarySegments.count == 2 }, "Numeric source segment labels share the same safe group binding and do not reopen compact-arrow parsing")
        let without132Quote = (realSourceIntro + first132Transfer).replacingOccurrences(of: "- **币种及报价**：CNY 630/人（不含税）", with: "")
        let unpriced132 = CtripFlightParser.offers(without132Quote, query: fresh132Query, at: fresh132.createdAt)[0]
        expect(unpriced132.isSchedule && unpriced132.cardPrice == "票价待查" && unpriced132.itinerarySegments.count == 2, "A complete new-format itinerary lacking its own quote remains a whole unpriced reference without borrowing a fare")
        let external132 = CtripFlightParser.offers(fresh132.text.replacingOccurrences(of: "来源：携程官方查询", with: "来源：其他网站"), query: fresh132Query, at: fresh132.createdAt)
        expect(external132.count == 10 && external132.allSatisfy { $0.isSchedule } && CtripFlightParser.recommendation("", representedBy: external132).preferredOfferID == nil, "The new complete formatting never promotes explicitly external-source plans into Ctrip quotations")
        let future132 = CtripFlightParser.offers(fresh132.text, query: fresh132Query, at: Date(timeIntervalSince1970: 3_000_000_000))
        expect(future132.map { $0.leg(departure: true).date + $0.leg(departure: false).date } == fresh132Cards.map { $0.leg(departure: true).date + $0.leg(departure: false).date }, "The complete new-format fixture cannot drift to a different journey date when replayed years later")
        let fixtureBytesAfter = try Data(contentsOf: fixtureURL)
        expect(fixtureBytesAfter == fixtureBytes, "The full real-response fixture remains byte-for-byte unchanged after every parser and ordering check")

        let localShanghaiSource = (realSourceIntro + first132Transfer).replacingOccurrences(of: "15:20 大兴出发", with: "15:20 上海浦东国际机场出发")
        let localShanghai = CtripFlightParser.offers(localShanghaiSource, query: fresh132Query, at: fresh132.createdAt)[0]
        expect(localShanghai.leg(departure: true).airport == "上海浦东国际机场" && localShanghai.itinerarySegments[0].departure.airport == "上海浦东国际机场" && localShanghai.selectionStatus == .doesNotMeet, "A global Beijing source route never prefixes or conceals a complete local Shanghai airport contradiction")
        let unknownShortAirportSource = (realSourceIntro + first132Transfer).replacingOccurrences(of: "15:20 大兴出发", with: "15:20 浦东 T2出发")
        let unknownShortAirport = CtripFlightParser.offers(unknownShortAirportSource, query: fresh132Query, at: fresh132.createdAt)[0]
        expect(unknownShortAirport.leg(departure: true).airport == "浦东 T2" && unknownShortAirport.itinerarySegments[0].departure.airport == "浦东 T2" && unknownShortAirport.selectionStatus == .insufficientInformation && CtripFlightParser.recommendation("", representedBy: [unknownShortAirport]).preferredOfferID == nil, "An unknown two-character endpoint cannot be assigned the global city merely because it has the shape of a short airport name")

        let wrongCityActualQuery = queried(fresh132Cards, fresh132Query.replacingOccurrences(of: "北京到深圳", with: "上海到深圳"))
        expect(wrongCityActualQuery.allSatisfy { $0.selectionStatus == .doesNotMeet } && CtripFlightParser.recommendation("", representedBy: wrongCityActualQuery).preferredOfferID == nil, "The exact real query prefix is parsed as a complete word, so changing its requested city cannot silently empty the hard route constraints")

        let priceFixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/build133-fresh-flight-price-response.json")
        let priceFixtureBytes = try Data(contentsOf: priceFixtureURL)
        let fresh133Price = try JSONDecoder().decode(Build132Fixture.self, from: priceFixtureBytes).message
        let fresh133PriceQuery = fresh133Price.flightQuery!
        let fresh133PriceCards = CtripFlightParser.offers(fresh133Price.text, query: fresh133PriceQuery, at: fresh133Price.createdAt)
        let expectedPriceSourceCodes = ["DZ6210", "ZH9151+ZH8934", "CA8623+CA3640", "ZH1023+ZH9140", "CA1461+CA3886"]
        expect(fresh133Price.text.count == 2437 && fresh133Price.text.contains("以上5个方案") && fresh133Price.flightOffers?.count == 1, "The second complete real fixture preserves the actual five-plan return and one-card stale cache, without inventing the ten plans in an earlier result")
        expect(fresh133PriceCards.count == 5 && fresh133PriceCards.allSatisfy { !$0.isSchedule } && codes(fresh133PriceCards) == expectedPriceSourceCodes, "Chinese-ordinal source headings keep five complete quoted plans in source order")
        expect(fresh133PriceCards[0].itinerarySegments.isEmpty && fresh133PriceCards.dropFirst().allSatisfy { $0.itinerarySegments.count == 2 }, "The separate time-arrow and airport-arrow layout binds four full two-leg cards without creating independently bookable legs")
        expect(fresh133PriceCards.map(\.cardPrice) == ["CNY 400元 · 不含税", "CNY 400元 · 不含税", "CNY 520元 · 不含税", "CNY 520元 · 不含税", "CNY 610元 · 不含税"], "The normalized compound quote label keeps the explicit CNY yuan amounts and tax qualification")
        expect(fresh133PriceCards.allSatisfy { $0.selectionStatus == .satisfied && CtripFlightParser.value("计价单位", in: $0.details) == "1名成人 / 单人票价" && $0.cardMetadata.contains("1名成人 / 单人票价") }, "Local typed-party and per-person unit fields survive label normalization without rewriting value spacing or inventing a group total")
        expect(fresh133PriceCards[0].cardMetadata.contains("经济舱（16.0%折扣）"), "The provider's explicit percentage-discount cabin form is shown unchanged rather than converted to another discount convention")
        expect(codes(CtripFlightParser.displayOrder(fresh133Price.text, representedBy: fresh133PriceCards)) == expectedPriceSourceCodes && CtripFlightParser.recommendation(fresh133Price.text, representedBy: fresh133PriceCards).preferredOfferID == fresh133PriceCards[0].id, "The actual full price-priority query ranks its same-basis prices before connection and duration tie-breakers")
        expect(fresh133PriceCards.allSatisfy { $0.leg(departure: true).airport.contains("北京") && $0.leg(departure: false).airport.contains("深圳") }, "Every new-format card's endpoints span the complete requested trip, never just the first connection")
        let separatePairs = fresh133PriceCards[1].itinerarySegments
        expect(separatePairs[0].departure == .init(time: "07:55", airport: "北京首都国际机场 T3", date: "2026-10-26") && separatePairs[0].arrival == .init(time: "10:00", airport: "刘集机场 T2", date: "2026-10-26"), "Time and airport arrows populate distinct endpoint fields of the same first segment")
        expect(separatePairs[1].departure.date == "2026-10-26" && separatePairs[1].departure.time == "22:50" && separatePairs[1].arrival.date == "2026-10-27" && separatePairs[1].arrival.time == "01:10", "The new second segment keeps both explicit calendar dates including the 27th arrival")
        expect(separatePairs[0].aircraft == "波音737" && separatePairs[0].duration == "2小时05分钟" && separatePairs[0].sourceText == "ZH9151（深圳航空），2026-10-26 07:55 出发 → 2026-10-26 10:00 到达，北京首都国际机场 T3 → 刘集机场 T2，波音737，飞行2小时05分钟", "Aircraft and source flying duration remain separate from intact time, airport and airline text")
        expect(fresh133PriceCards[1].leg(departure: false).date == "2026-10-27" && fresh133PriceCards[1].cardMetadata.contains("17小时15分钟") && fresh133PriceCards[1].cardSupplement.contains("1035分钟"), "The whole-card arrival date and explicit total duration agree with its complete final segment and retain the long raw qualification")
        expect(fresh133PriceCards.allSatisfy { !$0.cardSupplement.contains("价格说明：元") && !$0.cardSupplement.contains("价格说明：/") }, "Normal currency-unit and separator syntax is not misrepresented as an additional price qualification")
        expect(fresh133PriceCards.allSatisfy { $0.cardSupplement.contains("行李：待核实") && $0.cardSupplement.contains("退改：待核实") && $0.cardSupplement.contains("预订链接：待核实") }, "Separate unresolved policy and booking fields remain accessible on each complete new-format card")
        expect(CtripFlightSearchContext.latest(in: [fresh133Price])?.offers.map(\.id) == CtripFlightParser.displayOrder(fresh133Price.text, representedBy: fresh133PriceCards).map(\.id), "The second real response replaces its stale cache with the same complete five-option UI and follow-up sequence")
        let Shanghai133Query = queried(fresh133PriceCards, fresh133PriceQuery.replacingOccurrences(of: "北京到深圳", with: "上海到深圳"))
        expect(Shanghai133Query.allSatisfy { $0.selectionStatus == .doesNotMeet } && CtripFlightParser.recommendation("", representedBy: Shanghai133Query).preferredOfferID == nil, "Changing only the origin in the complete re-query prefix really enforces the new hard route instead of silently dropping it")
        let Guangzhou133Query = queried(fresh133PriceCards, fresh133PriceQuery.replacingOccurrences(of: "北京到深圳", with: "北京到广州"))
        expect(Guangzhou133Query.allSatisfy { $0.selectionStatus == .doesNotMeet } && CtripFlightParser.recommendation("", representedBy: Guangzhou133Query).preferredOfferID == nil, "Changing only the destination in the complete real price query really enforces its hard route")
        let labelVariants: [(String, String)] = [
            ("适用人数｜计价单位", "币种／报价／含税口径"),
            ("适用人数 及 计价单位", "币种 与 报价 和 含税口径"),
            ("适 用 人 数 / 计 价 单 位", "币 种 / 报 价 / 含 税 口 径")
        ]
        for (index, variant) in labelVariants.enumerated() {
            let variantText = fresh133Price.text.replacingOccurrences(of: "适用人数 / 计价单位", with: variant.0).replacingOccurrences(of: "币种 / 报价 / 含税口径", with: variant.1)
            let variantCards = CtripFlightParser.offers(variantText, query: fresh133PriceQuery, at: fresh133Price.createdAt)
            expect(codes(variantCards) == expectedPriceSourceCodes && variantCards.map(\.cardPrice) == fresh133PriceCards.map(\.cardPrice) && variantCards.allSatisfy { $0.selectionStatus == .satisfied }, "Semantic label separator and whitespace variant \(index + 1) preserves all source plans, amounts and party facts")
        }
        let splitMarkdownLabels = fresh133Price.text.replacingOccurrences(of: "**适用人数 / 计价单位**", with: "**适用人数** ／ **计价单位**").replacingOccurrences(of: "**币种 / 报价 / 含税口径**", with: "**币种** ｜ **报价** ｜ **含税口径**")
        expect(CtripFlightParser.offers(splitMarkdownLabels, query: fresh133PriceQuery, at: fresh133Price.createdAt).map(\.cardPrice) == fresh133PriceCards.map(\.cardPrice), "Markdown around individual label components does not change their semantic field identity")
        let unknownCompoundLabel = fresh133Price.text.replacingOccurrences(of: "币种 / 报价 / 含税口径", with: "币种 / 行李 / 报价")
        let unknownCompoundCards = CtripFlightParser.offers(unknownCompoundLabel, query: fresh133PriceQuery, at: fresh133Price.createdAt)
        expect(unknownCompoundCards.count == 5 && unknownCompoundCards.allSatisfy { $0.isSchedule }, "Normalization does not swallow an unrelated semantic component into a trusted quotation label")
        let second133Start = fresh133Price.text.range(of: "### 方案二：")!.lowerBound
        let second133End = fresh133Price.text.range(of: "### 方案三：")!.lowerBound
        let second133Block = String(fresh133Price.text[second133Start..<second133End])
        let isolated133Block = "来源：携程官方查询\n" + second133Block
        let localTypedOnly = CtripFlightParser.offers(isolated133Block, query: fresh133PriceQuery, at: Date(timeIntervalSince1970: 3_000_000_000))[0]
        expect(localTypedOnly.selectionStatus == .satisfied && CtripFlightParser.value("乘客", in: localTypedOnly.details) == "1位成人", "A local explicit one-adult unit is a source fact even when the global introduction is absent")
        let localUntypedOnly = CtripFlightParser.offers(isolated133Block.replacingOccurrences(of: "1名成人 / 单人票价", with: "1人 / 单人票价"), query: fresh133PriceQuery, at: fresh133Price.createdAt)[0]
        expect(localUntypedOnly.selectionStatus == .insufficientInformation && CtripFlightParser.value("乘客", in: localUntypedOnly.details).isEmpty, "An untyped one-person rate still cannot be upgraded to an adult from the user's query")
        let newPriceIntro = String(fresh133Price.text[..<fresh133Price.text.range(of: "### 方案一：")!.lowerBound])
        let conflictingTyped133 = CtripFlightParser.offers((newPriceIntro + second133Block).replacingOccurrences(of: "1名成人 / 单人票价", with: "2名成人 / 单人票价"), query: fresh133PriceQuery, at: fresh133Price.createdAt)[0]
        expect(conflictingTyped133.selectionStatus == .insufficientInformation && CtripFlightParser.recommendation("", representedBy: [conflictingTyped133]).preferredOfferID == nil, "A local typed two-adult unit contradicting the global one-adult scope stays unconfirmed")
        let conflictingUntyped133 = CtripFlightParser.offers((newPriceIntro + second133Block).replacingOccurrences(of: "1名成人 / 单人票价", with: "2人 / 单人票价"), query: fresh133PriceQuery, at: fresh133Price.createdAt)[0]
        expect(conflictingUntyped133.selectionStatus == .insufficientInformation, "Spaces around a local untyped person-count separator cannot conceal a source party-count contradiction")
        let missingAirportArrow133 = fresh133Price.text.replacingOccurrences(of: "北京首都国际机场 T3 → 刘集机场 T2", with: "北京首都国际机场 T3 / 刘集机场 T2")
        expect(CtripFlightParser.offers(missingAirportArrow133, query: fresh133PriceQuery, at: fresh133Price.createdAt).count == 4, "An ambiguous airport pair is not guessed from the time arrow or emitted as an isolated segment")
        let thirdAirportArrow133 = fresh133Price.text.replacingOccurrences(of: "北京首都国际机场 T3 → 刘集机场 T2", with: "北京首都国际机场 T3 → 中间机场 → 刘集机场 T2")
        expect(CtripFlightParser.offers(thirdAirportArrow133, query: fresh133PriceQuery, at: fresh133Price.createdAt).count == 4, "An unsupported extra airport arrow does not silently discard part of a source segment")
        let mismatch133Heading = fresh133Price.text.replacingOccurrences(of: "### 方案二：ZH9151 + ZH8934", with: "### 方案二：ZH9999 + ZH8934")
        expect(CtripFlightParser.offers(mismatch133Heading, query: fresh133PriceQuery, at: fresh133Price.createdAt).count == 4, "The new dual-arrow layout still requires the whole header code set to match its full segment set")
        let noGlobalDate133 = CtripFlightParser.offers(isolated133Block, query: fresh133PriceQuery, at: fresh133Price.createdAt)[0]
        expect(noGlobalDate133.itinerarySegments[1].arrival.date == "2026-10-27" && noGlobalDate133.itinerarySegments[0].departure.date == "2026-10-26", "Each explicit per-leg calendar date survives independently of query time and source global-date inheritance")
        let fresh133Narrative = CtripFlightParser.narrative(fresh133Price.text, representedBy: fresh133PriceCards)
        expect(!fresh133Narrative.contains("### 方案一") && !fresh133Narrative.contains("### 方案二") && !fresh133Narrative.contains("**第一段**") && !fresh133Narrative.contains("**币种 / 报价 / 含税口径**"), "The complete new source plans and their normalized fields do not leave a repeated itinerary list outside the cards")
        expect(CtripFlightParser.recommendation(fresh133Price.text, representedBy: fresh133PriceCards).advice.isEmpty, "Provider comparison prose never replaces deterministic selection policy")
        let futurePrice133 = CtripFlightParser.offers(fresh133Price.text, query: fresh133PriceQuery, at: Date(timeIntervalSince1970: 3_000_000_000))
        expect(codes(futurePrice133) == expectedPriceSourceCodes && futurePrice133.map { $0.leg(departure: false).date } == fresh133PriceCards.map { $0.leg(departure: false).date }, "The second actual response cannot gain or lose plans or drift its explicit journey dates on a later replay")
        let priceFixtureBytesAfter = try Data(contentsOf: priceFixtureURL)
        let firstFixtureBytesAgain = try Data(contentsOf: fixtureURL)
        expect(priceFixtureBytesAfter == priceFixtureBytes && firstFixtureBytesAgain == fixtureBytes, "Both complete real raw-response fixtures remain byte-identical after the combined regression run")

        let complete133Coverage = CtripFlightParser.coverage(fresh133Price.text, representedBy: fresh133PriceCards)
        expect(complete133Coverage.isReliable && complete133Coverage.isComplete && complete133Coverage.expectedGroupCount == 5 && complete133Coverage.representedGroupCount == 5, "All five real numbered source groups must be individually and completely represented before coverage is reported complete")
        let complete132Coverage = CtripFlightParser.coverage(fresh132.text, representedBy: fresh132Cards)
        expect(complete132Coverage.isComplete && complete132Coverage.expectedGroupCount == 10 && complete132Coverage.representedGroupCount == 10, "The first real ten-plan source uses the same source-heading and section coverage contract")
        let partial133Coverage = CtripFlightParser.coverage(fresh133Price.text, representedBy: [fresh133PriceCards[0]])
        let partial133Recommendation = CtripFlightParser.recommendation(fresh133Price.text, representedBy: [fresh133PriceCards[0]])
        expect(partial133Coverage.isReliable && !partial133Coverage.isComplete && partial133Coverage.expectedGroupCount == 5 && partial133Coverage.representedGroupCount == 1 && partial133Recommendation.preferredOfferID == nil, "One complete surviving card cannot silently become preferred when the real source explicitly gives five complete plan groups")
        let incompleteMessage = "部分方案信息尚不完整，暂不能确定首选。"
        expect(partial133Recommendation.commonNotes.components(separatedBy: incompleteMessage).count == 2, "Incomplete source coverage produces one concise data-boundary note independent of sorting-description visibility")
        expect(!CtripFlightParser.recommendation(fresh133Price.text, representedBy: fresh133PriceCards).commonNotes.contains(incompleteMessage), "A fully represented real source does not get a false partial-coverage warning")
        let stale133Coverage = CtripFlightParser.coverage(fresh133Price.text, representedBy: fresh133Price.flightOffers!)
        expect(!stale133Coverage.isComplete && CtripFlightParser.recommendation(fresh133Price.text, representedBy: fresh133Price.flightOffers!).preferredOfferID == nil, "The actual old one-card cache cannot certify full representation of the new source")
        expect(!CtripFlightParser.coverage(fresh132.text, representedBy: fresh132.flightOffers!).isComplete && CtripFlightParser.recommendation(fresh132.text, representedBy: fresh132.flightOffers!).preferredOfferID == nil, "The actual old sixteen isolated-leg cards cannot certify the original ten complete itinerary groups")
        let fragment133Cards = [fresh133PriceCards[0]] + fresh133PriceCards.dropFirst().flatMap { offer in
            offer.itinerarySegments.map { segment in policyOffer(segment.code, departure: segment.departure.time, arrival: segment.arrival.time, duration: segment.duration, price: offer.cardPrice) }
        }
        let fragmentCoverage = CtripFlightParser.coverage(fresh133Price.text, representedBy: fragment133Cards)
        expect(fragment133Cards.count == 9 && fragmentCoverage.representedGroupCount == 1 && !fragmentCoverage.isComplete && CtripFlightParser.recommendation(fresh133Price.text, representedBy: fragment133Cards).preferredOfferID == nil, "Nine apparent cards containing isolated connecting legs do not count as five whole source plans")
        let failedGroup133Cards = CtripFlightParser.offers(missingAirportArrow133, query: fresh133PriceQuery, at: fresh133Price.createdAt)
        expect(failedGroup133Cards.count == 4 && CtripFlightParser.recommendation(missingAirportArrow133, representedBy: failedGroup133Cards).preferredOfferID == nil && CtripFlightParser.recommendation(missingAirportArrow133, representedBy: failedGroup133Cards).commonNotes.contains(incompleteMessage), "An actual unsupported source-group detail format revokes preference even though four other real plans still parsed successfully")
        let unknownPlanBoundary = "来源：携程官方查询\n### 方案（甲）\n尚未能识别的完整行程内容"
        let unknownPlanCoverage = CtripFlightParser.coverage(unknownPlanBoundary, representedBy: [fresh133PriceCards[0]])
        expect(unknownPlanCoverage.hasPlanBoundaries && !unknownPlanCoverage.isReliable && !unknownPlanCoverage.isComplete && unknownPlanCoverage.expectedGroupCount == nil && CtripFlightParser.recommendation(unknownPlanBoundary, representedBy: [fresh133PriceCards[0]]).preferredOfferID == nil, "An unfamiliar possible plan boundary is not falsely certified as fully represented or converted into a guessed exact count")
        let unnamedPlanSource = fresh133Price.text.replacingOccurrences(of: "### 方案二：ZH9151 + ZH8934（深圳航空） — 中转1次", with: "### 方案二")
        let unnamedPlans = CtripFlightParser.offers(unnamedPlanSource, query: fresh133PriceQuery, at: fresh133Price.createdAt)
        expect(!CtripFlightParser.coverage(unnamedPlanSource, representedBy: unnamedPlans).isComplete && CtripFlightParser.recommendation(unnamedPlanSource, representedBy: unnamedPlans).preferredOfferID == nil, "A reliable numbered boundary without a representable full itinerary cannot disappear from the completeness check")
        let inflatedInventoryClaim = fresh133Price.text.replacingOccurrences(of: "以上5个方案", with: "以上999个方案")
        expect(CtripFlightParser.coverage(inflatedInventoryClaim, representedBy: fresh133PriceCards).expectedGroupCount == 5, "Coverage counts actual source plan boundaries and never the provider's claimed inventory quantity")
        let explanationOnlyHeading = fresh133Price.text + "\n## 方案对比与选择建议\n可根据个人出行需求选择。"
        expect(CtripFlightParser.coverage(explanationOnlyHeading, representedBy: fresh133PriceCards).isComplete, "A general comparison or advice heading is not mistaken for an additional itinerary group")
        let duplicateCoverageIDs = fresh133PriceCards.map { item -> CtripFlightOffer in var item = item; item.id = "same-legacy-id"; return item }
        expect(CtripFlightParser.coverage(fresh133Price.text, representedBy: duplicateCoverageIDs).isComplete, "Source-group coverage uses distinct offer positions and complete identities rather than deduplicating legacy IDs")
        let unassessableCoverage = CtripFlightParser.coverage("非结构化来源内容", representedBy: fresh133PriceCards)
        expect(!unassessableCoverage.isReliable && !unassessableCoverage.isComplete && unassessableCoverage.expectedGroupCount == nil, "Unstructured source content does not produce a fabricated claim that all source plans were covered")
        let rawOvernightClaim = fresh132Cards[9].field("中转机场")
        let qualifiedOvernight = fresh132Cards[9].transferAirport
        expect(rawOvernightClaim.contains("含过夜等待") && qualifiedOvernight.contains("过夜说明待核实") && !qualifiedOvernight.contains("含过夜等待") && qualifiedOvernight.contains("12小时50分钟"), "A source overnight-wait claim is qualified when the exact same transfer airport has two known same-day endpoints, without changing the source waiting duration")
        expect(fresh132Cards[9].details.contains("含过夜等待") && fresh132Cards[9].cardPrice == "CNY 400 · 不含税" && fresh132Cards[9].cardMetadata.contains("17小时15分钟"), "The bounded wait-claim qualifier never rewrites the original source details, quotation or total duration")
        var differentTransferAirport = fresh132Cards[9]
        differentTransferAirport.details = differentTransferAirport.details.replacingOccurrences(of: "22:50 刘集 T2", with: "22:50 刘集 T1")
        expect(differentTransferAirport.transferAirport.contains("含过夜等待") && !differentTransferAirport.transferAirport.contains("过夜说明待核实"), "Different transfer-airport strings, including distinct terminals, are not assumed to share a verified local waiting interval")
        var unknownWaitDate = fresh132Cards[9]
        unknownWaitDate.details = unknownWaitDate.details.replacingOccurrences(of: "2026-10-26", with: "").replacingOccurrences(of: "2026-10-27", with: "")
        expect(unknownWaitDate.transferAirport.contains("含过夜等待") && !unknownWaitDate.transferAirport.contains("过夜说明待核实"), "Missing source calendar dates prevent a negative overnight-wait conclusion despite plausible displayed clocks")
        var trueOvernightWait = fresh132Cards[9]
        trueOvernightWait.details = trueOvernightWait.details.replacingOccurrences(of: "ZH8934，2026-10-26 22:50", with: "ZH8934，2026-10-27 22:50").replacingOccurrences(of: "次日01:10", with: "2026-10-28 01:10")
        expect(trueOvernightWait.itinerarySegments[0].arrival.date == "2026-10-26" && trueOvernightWait.itinerarySegments[1].departure.date == "2026-10-27" && trueOvernightWait.transferAirport.contains("含过夜等待"), "A genuinely source-stated next-calendar-day transfer departure keeps its overnight explanation")
        var explicitUnknownWaitZone = fresh132Cards[9]
        explicitUnknownWaitZone.details = explicitUnknownWaitZone.details.replacingOccurrences(of: "波音737，125分钟", with: "波音737，125分钟，时区待核实")
        expect(explicitUnknownWaitZone.transferAirport.contains("含过夜等待") && !explicitUnknownWaitZone.transferAirport.contains("过夜说明待核实"), "An explicitly unresolved timezone qualification is not used to negate the source overnight claim")
        var noOvernightClaim = fresh132Cards[9]
        noOvernightClaim.details = noOvernightClaim.details.replacingOccurrences(of: "含过夜等待", with: "无需过夜等待")
        expect(noOvernightClaim.transferAirport.contains("无需过夜等待") && !noOvernightClaim.transferAirport.contains("过夜说明待核实"), "An already negative overnight statement is not reinterpreted as an affirmative unverified claim")

        let excludesWaiting = policyOffer("CA8001 + CA8002", duration: "2小时（不含中转等待）", kind: "中转", query: "最快优先")
        let completeWaitingDuration = policyOffer("MU8003 + MU8004", duration: "5小时（含中转等待）", kind: "中转", query: "最快优先")
        expect(CtripFlightParser.displayOrder("", representedBy: [excludesWaiting, completeWaitingDuration]).first?.id == completeWaitingDuration.id, "A source value explicitly excluding connection waiting cannot be treated as the shorter complete elapsed duration")
        expect(!excludesWaiting.cardMetadata.contains("2小时") && excludesWaiting.cardSupplement.contains("2小时（不含中转等待）"), "An invalid total-duration qualification remains in source information instead of being shortened to a confident two-hour total on the card")
        let excludesWaitingWithFlight = policyOffer("CA8005", duration: "2小时（未计入转机等待）", query: "最快优先", extra: "飞行时长：1小时")
        let explicitThreeHours = policyOffer("MU8006", duration: "3小时", query: "最快优先")
        expect(CtripFlightParser.displayOrder("", representedBy: [excludesWaitingWithFlight, explicitThreeHours]).first?.id == explicitThreeHours.id, "An explicitly disqualified total-duration field cannot be rescued by a shorter single-flight value")
        let stopoverFlightOnly = policyOffer("DZ8007", duration: "", kind: "经停", query: "最快优先", extra: "飞行时长：1小时")
        expect(CtripFlightParser.displayOrder("", representedBy: [stopoverFlightOnly, explicitThreeHours]).first?.id == explicitThreeHours.id, "A single source flight number plus stopover does not make its flight-only duration the whole trip including waiting")
        let unknownKindFlightOnly = policyOffer("CA8008", duration: "", kind: "", query: "最快优先", extra: "飞行时长：1小时")
        expect(CtripFlightParser.displayOrder("", representedBy: [unknownKindFlightOnly, explicitThreeHours]).first?.id == explicitThreeHours.id, "Unknown directness cannot use a flight-only time as a guessed complete journey duration")
        let explicitDirectFlightOnly = policyOffer("MF8009", duration: "", kind: "直飞", query: "最快优先", extra: "飞行时长：1小时")
        expect(CtripFlightParser.displayOrder("", representedBy: [explicitThreeHours, explicitDirectFlightOnly]).first?.id == explicitDirectFlightOnly.id, "An actually source-stated direct flight keeps its explicit single-flight duration capability when no total-duration field was returned")
        let mixedNote = "报价口径不同或未明确，未按金额排序。"
        let mixedDataNotes = CtripFlightParser.recommendation("", representedBy: mixedTax)
        expect(mixedDataNotes.commonNotes.components(separatedBy: mixedNote).count == 2 && !mixedDataNotes.sortDescription.contains(mixedNote), "Price-basis incomparability is one separate common data note and is not hidden or duplicated inside the optional sorting explanation")
        var partialDifferentCurrency = fresh133PriceCards[1]
        partialDifferentCurrency.details = partialDifferentCurrency.details.replacingOccurrences(of: "CNY 400元", with: "USD 400")
        partialDifferentCurrency.price = "USD 400 · 不含税"
        let combinedBoundaryNotes = CtripFlightParser.recommendation(fresh133Price.text, representedBy: [fresh133PriceCards[0], partialDifferentCurrency])
        expect(combinedBoundaryNotes.preferredOfferID == nil && combinedBoundaryNotes.commonNotes.components(separatedBy: mixedNote).count == 2 && combinedBoundaryNotes.commonNotes.components(separatedBy: incompleteMessage).count == 2, "Mixed currency and incomplete group coverage each appear once as independent common data boundaries, with no preferred offer")

        let legacyEncoded = try JSONEncoder().encode(offers[0])
        let legacyDecoded = try JSONDecoder().decode(CtripFlightOffer.self, from: legacyEncoded)
        expect(legacyDecoded.referenceOnly == nil, "Existing stored fare cards remain compatible without the optional reference flag")
        if CommandLine.arguments.count > 1 {
            let file = URL(fileURLWithPath: CommandLine.arguments[1])
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let records = document["records"] as! [[String: Any]]
            var selected: (query: String, text: String, at: Date)?
            for record in records {
                let messages = record["messages"] as! [[String: Any]]
                for (index, message) in messages.enumerated() {
                    let query = message["text"] as? String ?? ""
                    guard message["role"] as? String == "user", ["深圳", "北京", "明天", "上午"].allSatisfy({ query.contains($0) }) else { continue }
                    for reply in messages.dropFirst(index + 1) {
                        if reply["role"] as? String == "user" { break }
                        guard reply["role"] as? String == "assistant", let text = reply["text"] as? String,
                              let timestamp = reply["createdAt"] as? Double else { continue }
                        let date = Date(timeIntervalSinceReferenceDate: timestamp)
                        if selected == nil || date > selected!.at { selected = (query, text, date) }
                        break
                    }
                }
            }
            expect(selected != nil, "Actual copied archive contains the targeted morning query without printing other conversations")
            let original = selected!
            let actual = CtripFlightParser.offers(original.text, query: original.query, at: original.at).filter { !$0.isSchedule }
            expect(actual.count == 5 && actual.first?.cardTitle.contains("MU6670") == true && actual.last?.cardTitle.contains("ZH1338") == true, "Full unmodified phone response produces the five official fare cards")
            expect(actual.map(\.cardPrice) == ["1270元 · 不含机建燃油税费", "1305元 · 不含机建燃油税费", "1660元 · 不含机建燃油税费", "600元 · 不含机建燃油税费", "1830元 · 不含机建燃油税费"], "Actual full-response monetary amounts remain correctly assigned")
            expect(actual.allSatisfy { $0.leg(departure: true).date == "2026-10-25" && $0.leg(departure: false).date == "2026-10-26" }, "Actual 11:49pm archived tomorrow query retains October 25 departure and October 26 arrival")
            let actualNarrative = CtripFlightParser.narrative(original.text, representedBy: actual)
            expect(["ZH9101", "HU7702", "MU6662", "CZ3171", "HU7704", "CA1334", "CZ3151"].allSatisfy { actualNarrative.contains($0) }, "All seven network-only actual references remain available outside Ctrip cards")
            expect(actual.allSatisfy { !$0.cardWarnings.isEmpty } && actualNarrative.contains("未检索到上午出发的直飞航班"), "Actual mismatched morning requirement remains visible on cards and in text")
            let replay = CtripFlightParser.offers(original.text, query: original.query, at: Date(timeIntervalSince1970: 2_000_000_000)).filter { !$0.isSchedule }
            expect(replay.map { $0.leg(departure: true).date + $0.leg(departure: false).date } == actual.map { $0.leg(departure: true).date + $0.leg(departure: false).date }, "Actual archived reply cannot change journey dates when displayed after midnight or years later")
        }
        print("Flight presentation checks passed (\(checks) checks; offline source and legacy fixtures)")
    }
}
