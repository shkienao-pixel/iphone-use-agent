import Foundation

@main struct FlightSelectionChecks {
    static var results = [[String:Any]]()
    static func expect(_ value: Bool, _ name: String) {
        results.append(["name":name,"passed":value])
        if !value { fputs("FAIL: " + name + "\n", stderr) }
    }
    static func source(at now: Date, duplicate: Bool = false) -> AssistantMessage {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:"Asia/Shanghai");formatter.dateFormat="yyyy-MM-dd"
        let date = formatter.string(from:now.addingTimeInterval(86400))
        let query = "查询" + date + "深圳到北京单程直飞经济舱，1位成人"
        func text(_ code:String,_ price:Int,_ time:String)->String {
            "### " + code + "\n出发日期：" + date + "\n出发时间：" + time + "\n到达时间：23:55\n出发城市：深圳\n到达城市：北京\n出发机场：深圳宝安国际机场 T3\n到达机场：北京大兴国际机场\n航程类型：直飞\n舱位：经济舱\n乘客：1位成人\n计价单位：1人/单程\n价格：CNY \(price)/人（不含税）"
        }
        let raw="来源：携程官方查询\n"+text("MF8336",450,"12:10")+"\n\n"+text(duplicate ? "MF8336" : "MF8350",398,"21:00")
        var message=AssistantMessage(role:"assistant",text:raw)
        message.createdAt=now.addingTimeInterval(-30);message.flightQuery=query
        message.flightOffers=CtripFlightParser.offers(raw,query:query,at:message.createdAt)
        return message
    }
    static func resolve(_ text:String,_ history:[AssistantMessage],_ now:Date,pending:Bool=false)->ConversationRoute? {
        ConversationFlightSelectionResolver.route(question:text,history:history,now:now,timeZoneIdentifier:"Asia/Shanghai",hasPendingClarification:pending)
    }
    @MainActor static func fixture(_ question:String="第一班", missingTime:Bool=false)->(PhoneAgentViewModel,ConversationRoute,UUID,UUID) {
        let vm=PhoneAgentViewModel(),now=Date(),user=AssistantMessage(role:"user",text:question),reply=AssistantMessage(role:"assistant",text:"准备中")
        var source=source(at:now)
        if missingTime {
            source.text=source.text.replacingOccurrences(of:"出发时间：21:00\n",with:"")
            source.flightOffers=CtripFlightParser.offers(source.text,query:source.flightQuery!,at:source.createdAt)
        }
        vm.conversation.messages=[source,user,reply]
        let owner=UUID(),token=UUID();vm.conversation.claimPresentation(owner)
        vm.conversation.setFlightOpeningVisible(true,owner:owner);vm.conversation.setRequestToken(token)
        var route=resolve(question,[source],now)!
        route.flightOpenAuthorization = .init(conversationID:vm.conversation.currentConversationID,userMessageID:user.id,
            requestToken:token,presentationRevision:vm.conversation.flightOpeningPresentationRevision!)
        return (vm,route,reply.id,owner)
    }
    @MainActor static func settle() async {
        for _ in 0..<10000 { await Task.yield();if !CtripFlightHandoffCoordinator.shared.isRunning && !UIApplication.shared.events.isEmpty { return } }
    }
    @MainActor static func main() async throws {
        let now=ISO8601DateFormatter().date(from:"2026-10-26T11:00:00Z")!,original=source(at:now)
        let history=[original]
        expect(original.flightOffers?.count==2,"real parser builds two fixture cards")
        for input in ["第一班","选第一班","就选第一班吧","打开第一班","帮我打开第一班的选价页","MF8350","打开MF8350","打开 mf8350 的详情页"] {
            let route=resolve(input,history,now)
            expect(route?.mode == .flightOpen && route?.flightSelection?.offer.title.contains("MF8350")==true,"exact local opening: "+input)
        }
        for input in ["第二班","第2班","最后一班","倒数第一班"] {
            expect(resolve(input,history,now)?.flightSelection?.offer.title.contains("MF8336")==true,"UI order: "+input)
        }
        for input in ["这班","就这班","第一百班","第三班","打开CA1234"] {
            expect(resolve(input,history,now)?.mode != .flightOpen,"ambiguous or absent flight never opens: "+input)
        }
        for input in ["第一班多少钱","不要打开第一班","先别选第一班","解释一下第一班","打开第一班然后付款","第一班和第二班","“打开第一班”","第一班改成明天","第一班行李有多少"] {
            expect(resolve(input,history,now)?.mode != .flightOpen,"query/negative/quote/mixed turn never gains local authority: "+input)
        }
        expect(resolve("帮我预订第一班",history,now)?.mode == .clarify,"booking request does not become order authority")
        expect(resolve("第一班",history,now,pending:true)==nil,"ordinal cannot answer an unrelated pending clarification")
        expect(resolve("打开第一班",history,now,pending:true)?.mode == .flightOpen,"explicit opening remains independent of a pending form")
        expect(resolve("第一班",[],now)?.mode == .clarify,"no current source does not search arbitrary history")
        expect(resolve("第一班",[AssistantMessage(role:"user",text:original.text)],now)?.mode == .clarify,"quoted user text does not become flight source")
        var stale=original;stale.createdAt=now.addingTimeInterval(-1801)
        expect(resolve("第一班",[stale],now)?.mode == .clarify,"expired result asks for fresh query")
        var empty=AssistantMessage(role:"assistant",text:"没有可售航班");empty.flightQuery=original.flightQuery;empty.flightOffers=[];empty.createdAt=now
        expect(resolve("第一班",history+[empty],now)?.mode == .clarify,"newer empty result prevents replaying older cards")
        var incomplete=original;incomplete.text=incomplete.text.replacingOccurrences(of:"舱位：经济舱",with:"舱位：待核实")
        expect(resolve("第一班",[incomplete],now)?.mode == .flightOpen,"missing cabin with exact flight/date/city anchors reaches bounded supplement flow")
        var missingTime = original
        missingTime.text = missingTime.text.replacingOccurrences(of: "出发时间：21:00\n", with: "")
        expect(resolve("打开MF8350", [missingTime], now)?.mode == .flightOpen, "a dated named flight can supplement its missing departure clock")
        var undated = missingTime
        undated.text = undated.text.replacingOccurrences(of: "出发日期：2026-10-27\n", with: "")
        undated.flightQuery = "明天深圳到北京"
        undated.flightOffers = CtripFlightParser.offers(undated.text, query: undated.flightQuery!, at: undated.createdAt)
        expect(resolve("打开MF8350", [undated], now)?.mode == .clarify, "a relative-only source cannot invent its lookup date")
        var single=original;single.text=original.text.components(separatedBy:"\n\n")[0];single.flightOffers=CtripFlightParser.offers(single.text,query:single.flightQuery!,at:single.createdAt)
        expect(resolve("就这班",[single],now)?.flightSelection?.offer.title.contains("MF8336")==true,"deictic reference works only for one current candidate")
        let nextTopic=AssistantMessage(role:"assistant",text:"这里有两家餐厅可选")
        expect(resolve("第二个",history+[nextTopic],now)==nil,"newer nonflight choices own a generic ordinal")
        expect(resolve("它",history+[nextTopic],now)==nil,"newer nonflight answer owns a generic pronoun")
        expect(resolve("打开第一班",history+[nextTopic],now)?.mode == .flightOpen,"explicit flight reference can still name current flight source")
        expect(resolve("打开第二个",history,now,pending:true)==nil,"generic open cannot steal another pending choice")
        var clarification=AssistantMessage(role:"assistant",text:"请明确航班")
        var intent=resolve("这班",history,now)!.record
        intent.diagnostics = .init(memoryMilliseconds:0,routingMilliseconds:0,recalledSourceCount:0,recentMessageCount:1,decisionSource:"localFlightSelection")
        clarification.intent=intent
        expect(resolve("第一班",history+[clarification],now,pending:true)?.mode == .flightOpen,"answer to local flight clarification continues selection")
        var today=original;today.text=today.text.replacingOccurrences(of:"2026-10-27",with:"2026-10-26");today.flightQuery=today.flightQuery!.replacingOccurrences(of:"2026-10-27",with:"2026-10-26")
        today.flightOffers=CtripFlightParser.offers(today.text,query:today.flightQuery!,at:today.createdAt)
        expect(resolve("打开MF8336",[today],now)?.mode == .clarify,"today's already departed flight cannot automatically open")
        expect(ConversationFlightSelectionResolver.route(question:"打开MF8350",history:[today],now:now,timeZoneIdentifier:"Pacific/Kiritimati")?.mode == .flightOpen,"Chinese flight time is independent of device's next-day timezone")
        let selection=resolve("第一班",history,now)!.flightSelection!
        expect(ConversationFlightSelectionResolver.isCurrent(selection,history:history,now:now),"captured source remains current")
        var altered=original;altered.text += "\n来源更正"
        expect(!ConversationFlightSelectionResolver.isCurrent(selection,history:[altered],now:now),"same ID edited source invalidates lease")
        expect(!ConversationFlightSelectionResolver.isCurrent(selection,history:history,now:now.addingTimeInterval(61)),"opening request expires after sixty seconds")
        var host=resolve("第一班",history,now)!
        host.flightOpenAuthorization = .init(conversationID:UUID(),userMessageID:UUID(),requestToken:UUID(),presentationRevision:UUID())
        let decoded=try JSONDecoder().decode(ConversationRoute.self,from:JSONEncoder().encode(host))
        expect(decoded.flightSelection==nil && decoded.flightOpenAuthorization==nil,"archive or model JSON cannot recreate host selection authority")

        UIApplication.shared.reset();UIPasteboard.general.reset()
        do {
            let (vm,route,reply,_) = fixture();vm.openConversationFlight(route,replyID:reply,conversationID:vm.conversation.currentConversationID)
            await settle()
            expect(UIApplication.shared.openedURLs.count==1 && UIApplication.shared.openedURLs[0].path=="/flight_inland_singletransition","spoken selection opens one exact native page")
            expect(UIPasteboard.general.writes==1 && UIApplication.shared.clipboardPreparedAtOpen==[true],"spoken selection shares verified clipboard before app entry")
            expect(vm.conversation.messages.last?.text.contains("请求")==true && vm.conversation.messages.last?.text.contains("实际页面")==true,"reply records request, not verified landing or order")
        }
        UIApplication.shared.reset();UIPasteboard.general.reset()
        do {
            UIApplication.shared.specificAccepted=false
            let (vm,route,reply,_) = fixture();vm.openConversationFlight(route,replyID:reply,conversationID:vm.conversation.currentConversationID);await settle()
            expect(UIApplication.shared.openedURLs.map(\.path)==["/flight_inland_singletransition"],"failed exact spoken opening never falls back to list or home")
        }
        for reason in ["cancelled","hidden","crossConversation","sourceRemoved","newUser","background","forged"] {
            UIApplication.shared.reset();UIPasteboard.general.reset()
            let (vm,originalRoute,reply,owner) = fixture();var route=originalRoute
            let origin=vm.conversation.currentConversationID
            switch reason {
            case "cancelled":vm.conversation.setRequestToken(UUID())
            case "hidden":vm.conversation.setFlightOpeningVisible(false,owner:owner)
            case "crossConversation":vm.conversation.currentConversationID=UUID()
            case "sourceRemoved":vm.conversation.messages.removeFirst()
            case "newUser":vm.conversation.messages.append(.init(role:"user",text:"先不要打开"))
            case "background":UIApplication.shared.applicationState = .background
            default:route.flightOpenAuthorization=nil
            }
            vm.openConversationFlight(route,replyID:reply,conversationID:origin)
            for _ in 0..<50 { await Task.yield() }
            expect(UIApplication.shared.openedURLs.isEmpty && UIPasteboard.general.writes==0,"no clipboard or app action after "+reason)
        }
        UIApplication.shared.reset();UIPasteboard.general.reset()
        do {
            let (vm,route,reply,_) = fixture();let origin=vm.conversation.currentConversationID
            vm.openConversationFlight(route,replyID:reply,conversationID:origin)
            vm.conversation.setRequestToken(UUID())
            let cancellationText="用户已取消，保留这条说明"
            vm.conversation.messages[vm.conversation.messages.count-1].text=cancellationText
            for _ in 0..<50 {await Task.yield()}
            expect(UIApplication.shared.openedURLs.isEmpty && vm.conversation.messages.last?.text==cancellationText,"cancellation before queued opener cannot act or overwrite reply")
        }
        UIApplication.shared.reset();UIPasteboard.general.reset()
        do {
            UIApplication.shared.holdSpecific=true
            let (vm,route,reply,_) = fixture();let origin=vm.conversation.currentConversationID
            vm.openConversationFlight(route,replyID:reply,conversationID:origin)
            await UIApplication.shared.waitForSpecific()
            let beforeDuplicate=vm.conversation.messages.last!.text
            vm.openConversationFlight(route,replyID:reply,conversationID:origin)
            expect(UIPasteboard.general.writes==1 && UIApplication.shared.openedURLs.count==1,"same process token cannot replay the opening")
            expect(vm.conversation.messages.last?.text==beforeDuplicate,"duplicate callback cannot overwrite the first opening receipt")
            vm.conversation.setRequestToken(UUID());let cancellationText="用户取消了本次打开"
            vm.conversation.messages[vm.conversation.messages.count-1].text=cancellationText
            UIApplication.shared.resumeSpecific(false);await settle()
            expect(UIApplication.shared.openedURLs.count==1,"cancellation during accepted-call wait cannot start a fallback")
            expect(vm.conversation.messages.last?.text==cancellationText,"late OS failure cannot overwrite cancellation at unchanged last user")
        }
        UIApplication.shared.reset();UIPasteboard.general.reset()
        do {
            let (vm,route,reply,_) = fixture("打开MF8350",missingTime:true)
            var queries=0
            let actual=source(at:Date()).text
            vm.conversation.flightQuery={ _ in queries+=1;return actual }
            vm.openConversationFlight(route,replyID:reply,conversationID:vm.conversation.currentConversationID)
            await settle()
            expect(queries==1 && UIApplication.shared.openedURLs.count==1 && UIApplication.shared.openedURLs[0].path=="/flight_inland_singletransition", "spoken incomplete flight performs one bounded lookup and exact opening")
            expect(UIPasteboard.general.string?.contains("21:00")==true && vm.conversation.messages[0].text.contains("出发时间：21:00")==false, "spoken supplement uses returned facts without replacing original source")
        }
        UIApplication.shared.reset();UIPasteboard.general.reset()
        do {
            let (vm,route,reply,_) = fixture("打开MF8350",missingTime:true)
            var queries=0
            var pending:CheckedContinuation<String,Never>?
            let actual=source(at:Date()).text
            vm.conversation.flightQuery={ _ in queries+=1;return await withCheckedContinuation { pending=$0 } }
            let origin=vm.conversation.currentConversationID
            vm.openConversationFlight(route,replyID:reply,conversationID:origin)
            for _ in 0..<10000 { if pending != nil { break };await Task.yield() }
            expect(pending != nil && queries==1,"spoken supplement begins under original request lease")
            vm.openConversationFlight(route,replyID:reply,conversationID:origin)
            expect(queries==1,"same spoken authorization cannot duplicate the supplemental query")
            vm.conversation.setRequestToken(UUID())
            vm.conversation.messages[vm.conversation.messages.count-1].text="用户取消了本次补查打开"
            pending?.resume(returning:actual)
            for _ in 0..<10000 { if !CtripFlightHandoffCoordinator.shared.isRunning {break};await Task.yield() }
            expect(UIApplication.shared.openedURLs.isEmpty && UIPasteboard.general.writes==0,"cancelled spoken lookup cannot open or copy its late result")
            expect(vm.conversation.messages.last?.text=="用户取消了本次补查打开","late lookup cannot overwrite spoken cancellation")
        }
        let passed=results.filter{$0["passed"] as? Bool == true}.count
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":passed,"total":results.count,"checks":results],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        if passed != results.count { exit(1) }
    }
}
