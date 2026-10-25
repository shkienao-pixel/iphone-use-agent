import Foundation

@main struct CardUXChecks {
    static var checks = [[String:Any]]()
    static func check(_ name:String,_ condition:Bool) {
        checks.append(["name":name,"passed":condition])
    }
    static func offer(details:String,title:String="CA1001 + CA1002") -> CtripFlightOffer {
        CtripFlightOffer(id:"test",title:title,details:details,price:"CNY 600",bookingURL:nil,query:"",queriedAt:Date(timeIntervalSince1970:0))
    }
    static func reply(query:String="normalized default: 价格、总耗时、排序") -> AssistantMessage {
        var m=AssistantMessage(role:"assistant",text:"flight batch")
        m.flightQuery=query
        return m
    }
    static func show(_ human:String, prior:Bool=true) -> Bool {
        let first=AssistantMessage(role:"user",text:"明天北京到深圳，没有指定排序偏好，按默认规则推荐")
        let current=reply()
        let messages=prior ? [first,reply(),AssistantMessage(role:"user",text:human),current] : [AssistantMessage(role:"user",text:human),current]
        return CtripFlightCardPresentationPolicy.showsSortExplanation(messageID:current.id,messages:messages)
    }
    static func main() throws {
        let hidden=[
          "没有指定排序偏好，按默认规则推荐", "无指定排序偏好，按默认规则推荐", "按默认规则推荐", "查询北京到深圳的票", "保留直飞和中转方案", "改成上午出发，其余不变", "只看大兴出发", "增加1名成人", "价格低于600元", "只要直飞", "不要解释排序", "不要解释排序，改成价格优先", "不要显示任何排序说明，价格优先", "排序不用解释，价格优先", "不要改排序", "不要改排序，价格优先", "不用改变当前排序，早飞优先", "保留原来排序，价格优先", "不要按价格排序", "不要价格优先", "不想价格优先", "无需改排序", "不要调整航班排序", "不是价格优先", "并非价格优先", "不改排序，价格优先", "不解释排序，改成价格优先", "不按价格排序", "排序不变，价格优先", "不调整排序，价格优先"
        ]
        for q in hidden { check("hide: "+q,!show(q)) }
        let visible=["改成价格优先，其余条件不变", "价格优先", "按价格排序", "按价格从低到高排序", "按照价格由低到高排列", "低价优先", "改为总耗时优先", "按总耗时排序", "改为耗时最短", "少中转优先", "改成最少中转优先", "早飞优先", "早到优先", "直飞优先", "改回默认排序", "重新排序", "便宜的排前面", "不要按价格排序，改成总耗时优先"]
        for q in visible { check("show: "+q,show(q)) }
        check("first request explicit price is still hidden",!show("价格优先",prior:false))
        let current=reply(), unrelated=AssistantMessage(role:"assistant",text:"先前提到飞机")
        let noBatch=[AssistantMessage(role:"user",text:"你好"),unrelated,AssistantMessage(role:"user",text:"价格优先"),current]
        check("unrelated assistant is not a batch",!CtripFlightCardPresentationPolicy.showsSortExplanation(messageID:current.id,messages:noBatch))
        check("unknown message id is hidden",!CtripFlightCardPresentationPolicy.showsSortExplanation(messageID:UUID(),messages:noBatch))
        let historical=reply()
        let history=[AssistantMessage(role:"user",text:"初次查票"),historical,AssistantMessage(role:"user",text:"改成价格优先"),reply()]
        check("later raw turn cannot change old message policy",!CtripFlightCardPresentationPolicy.showsSortExplanation(messageID:historical.id,messages:history))
        check("normalized price query cannot supply human intent",!show("只看上午出发，其余条件不变"))
        check("short price explanation",CtripFlightCardPresentationPolicy.shortSortExplanation("排序：同口径报价低 → 中转次数少 → 总耗时短 → 起飞早。") == "已按价格优先调整。")
        check("incomparable price explanation is truthful",CtripFlightCardPresentationPolicy.shortSortExplanation("排序：同口径报价低 → 中转次数少。报价口径不同或未明确，未按金额排序。") == "报价口径不同或未明确，暂未按金额排序。")
        let total=offer(details:"航程类型：中转\n总耗时：6小时35分钟（395分钟）\n飞行时长：4小时25分钟\n舱位：经济舱\n计价单位：1人/单程")
        check("whole duration uses returned total",CtripFlightCardPresentationPolicy.wholeJourneyDuration(total)=="6小时35分钟")
        check("metadata removes repeated whole duration",CtripFlightCardPresentationPolicy.summaryMetadata(total)==["经济舱","4小时25分钟","1人/单程"])
        let noTotal=offer(details:"航程类型：中转\n飞行时长：4小时25分钟\n出发日期：2026-10-26\n出发时间：08:00\n到达时间：18:00\n舱位：经济舱")
        check("flight duration and endpoint clocks never fill total",CtripFlightCardPresentationPolicy.wholeJourneyDuration(noTotal)=="待核实")
        check("unknown total keeps independent flight metadata",CtripFlightCardPresentationPolicy.summaryMetadata(noTotal).contains("4小时25分钟"))
        for bad in ["待核实","未知","6小时35分钟（不含中转等待）","6小时35分钟（仅飞行）"] {
            check("unknown or excluded wait is not relabeled: "+bad,CtripFlightCardPresentationPolicy.wholeJourneyDuration(offer(details:"总耗时："+bad))=="待核实")
        }
        check("conflicting returned totals are unknown",CtripFlightCardPresentationPolicy.wholeJourneyDuration(offer(details:"总耗时：6小时35分钟\n总耗时：7小时35分钟"))=="待核实")
        check("duplicate identical totals accepted",CtripFlightCardPresentationPolicy.wholeJourneyDuration(offer(details:"总耗时：6小时35分钟\n总耗时：6小时35分钟"))=="6小时35分钟")
        check("direct metadata remains intact",CtripFlightCardPresentationPolicy.summaryMetadata(offer(details:"总耗时：4小时25分钟\n舱位：经济舱",title:"CA1001"))==["经济舱","4小时25分钟"])
        let complete=offer(details:"出发日期：2026-10-26\n出发时间：08:00\n到达时间：09:00\n价格：CNY 600/人（不含税）\n乘客：1位成人",title:"CA1001")
        let boundary=CtripFlightRecommendation(preferredOfferID:nil,advice:"",commonNotes:"部分方案信息尚不完整，暂不能确定首选。")
        check("incomplete coverage does not label first row preferred",CtripFlightCardPresentationPolicy.preferredHeading(complete,recommendation:boundary)=="可选方案")
        let confirmed=CtripFlightRecommendation(preferredOfferID:complete.id,advice:"",commonNotes:"行李信息待核实。")
        check("normal source note does not cancel confirmed preferred",CtripFlightCardPresentationPolicy.preferredHeading(complete,recommendation:confirmed)=="优先方案")
        let conflict=offer(details:"出发日期：2026-10-27\n出发时间：08:00\n价格：CNY 600")
        var constrained=conflict;constrained.query="查询2026年10月26日北京到深圳机票"
        check("boundary retains nonmatching status heading",CtripFlightCardPresentationPolicy.preferredHeading(constrained,recommendation:boundary)=="不符合条件的方案")
        check("conflicting total is removed from lower summary",CtripFlightCardPresentationPolicy.summaryMetadata(offer(details:"总耗时：6小时35分钟\n总耗时：7小时35分钟")).isEmpty)
        let file=URL(fileURLWithPath:CommandLine.arguments[1])
        let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        let m=raw["message"] as! [String:Any]
        let offers=CtripFlightParser.offers(m["text"] as! String,query:m["flightQuery"] as! String)
        let expected=["6小时35分钟","6小时35分钟","7小时55分钟","7小时55分钟","9小时30分钟","9小时30分钟","14小时20分钟","17小时15分钟"]
        let transfers=offers.filter(CtripFlightCardPresentationPolicy.isTransfer)
        check("fresh source has exactly eight transfer total headers",transfers.count==8)
        check("fresh source total values preserve waiting-inclusive totals",transfers.map(CtripFlightCardPresentationPolicy.wholeJourneyDuration)==expected)
        check("fresh source removes all duplicate total summary values",transfers.allSatisfy { o in !CtripFlightCardPresentationPolicy.summaryMetadata(o).contains(CtripFlightCardPresentationPolicy.wholeJourneyDuration(o)) && !CtripFlightCardPresentationPolicy.summaryMetadata(o).contains(o.field("总耗时")) })
        check("each fresh transfer still has two independent leg durations",transfers.allSatisfy { $0.itinerarySegments.count==2 && $0.itinerarySegments.allSatisfy { !$0.duration.isEmpty } })
        let passed=checks.filter { $0["passed"] as? Bool == true }.count
        let result:[String:Any]=["passed":passed,"total":checks.count,"checks":checks]
        let output=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
        if passed != checks.count { Foundation.exit(1) }
    }
}
