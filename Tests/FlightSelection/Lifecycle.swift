import Foundation

@main struct FlightSelectionLifecycle {
    @MainActor static func main() async throws {
        var checks=0,failures=[String]()
        func expect(_ condition:Bool,_ label:String) { checks+=1;if !condition {failures.append(label)} }
        func settle(_ predicate:()->Bool) async throws {
            for _ in 0..<3000 { if predicate() {return};try await Task.sleep(nanoseconds:1_000_000) }
            throw NSError(domain:"FlightSelectionLifecycle",code:1)
        }
        func drain() async { for _ in 0..<50 {await Task.yield()};try? await Task.sleep(nanoseconds:20_000_000) }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("sela-flight-open-lifecycle-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let settings=AgentSettings(),memories=MemoryStore(),model=OfflineModel.shared
        let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd";formatter.timeZone=TimeZone(identifier:"Asia/Shanghai")
        let day=formatter.string(from:Date().addingTimeInterval(86400))
        let question="查询"+day+"深圳到北京单程直飞经济舱，1位成人"
        let raw="来源：携程官方查询\n### MF8350\n出发日期："+day+"\n出发时间：21:00\n到达时间：23:55\n出发城市：深圳\n到达城市：北京\n出发机场：深圳宝安国际机场 T3\n到达机场：北京大兴国际机场\n航程类型：直飞\n舱位：经济舱\n乘客：1位成人\n计价单位：1人/单程\n价格：398元/人（不含税）"
        let c=AssistantConversation(store:AssistantConversationStore(url:folder.appendingPathComponent("chat.json")))
        let owner=UUID();c.claimPresentation(owner);c.setFlightOpeningVisible(true,owner:owner)
        c.unifiedRoute={ _ in .init(mode:.flightQuery,request:question,message:"") }
        var queryCount=0
        c.flightQuery={ _ in queryCount+=1;return raw }
        c.draft=question
        expect(c.send(settings:settings,apiKey:"",memories:memories),"initial query accepted")
        try await settle { !c.loading }
        expect(c.messages.last?.flightOffers?.count==1,"real send stores parsed source card")
        let modelCount=model.requests.count
        var dispatches=0,validClaims=0,lastOrigin:UUID?
        c.onActionInConversation={ route,reply,origin in
            guard route.mode == .flightOpen else {return}
            dispatches+=1;lastOrigin=origin
            if let selection=route.flightSelection,let auth=route.flightOpenAuthorization,
               c.claimFlightOpen(selection,authorization:auth,question:route.request) {validClaims+=1}
            c.reportTaskHandoff(text:"离线测试已接收打开请求",to:reply,in:origin)
        }
        c.unifiedRoute={ input in ConversationFlightSelectionResolver.route(question:input.question,history:input.flightSelectionHistory,
            now:input.referenceTime,timeZoneIdentifier:input.timeZoneIdentifier,hasPendingClarification:input.pendingIntent != nil)! }
        c.draft="第一班"
        expect(c.send(settings:settings,apiKey:"",memories:memories),"spoken first-flight turn accepted")
        try await settle { !c.loading };await drain()
        expect(dispatches==1 && validClaims==1,"real send publishes one bound local flight action")
        expect(lastOrigin==c.currentConversationID && c.messages.last?.intent?.mode == .flightOpen,"local route remains attached to originating chat and reply")
        expect(queryCount==1 && model.requests.count==modelCount,"selection performs no new model or flight query")
        expect(c.messages.last?.text=="离线测试已接收打开请求","host acknowledgement replaces preparation reply")

        var pending:CheckedContinuation<ConversationRoute,Never>?
        var delayed:ConversationRoute?
        c.unifiedRoute={ input in
            delayed=ConversationFlightSelectionResolver.route(question:input.question,history:input.flightSelectionHistory,
                now:input.referenceTime,timeZoneIdentifier:input.timeZoneIdentifier)
            return await withCheckedContinuation {pending=$0}
        }
        c.draft="打开MF8350";_ = c.send(settings:settings,apiKey:"",memories:memories)
        try await settle {pending != nil};c.cancel();pending!.resume(returning:delayed!);pending=nil;await drain()
        expect(dispatches==1 && validClaims==1,"real cancellation before route return prevents action dispatch")
        expect(c.draft=="打开MF8350","cancel retains the user's opening request")
        c.draft="打开MF8350";_ = c.send(settings:settings,apiKey:"",memories:memories)
        try await settle {pending != nil};c.releasePresentation(owner);pending!.resume(returning:delayed!);pending=nil
        try await settle {!c.loading};await drain()
        expect(dispatches==2 && validClaims==1,"page departure invalidates real captured visibility lease")
        c.claimPresentation(owner);c.setFlightOpeningVisible(true,owner:owner)
        c.draft="打开MF8350";_ = c.send(settings:settings,apiKey:"",memories:memories)
        try await settle {pending != nil};let origin=c.currentConversationID;c.newConversation()
        pending!.resume(returning:delayed!);pending=nil;await drain()
        expect(validClaims==1 && c.messages.isEmpty,"late original-chat route cannot claim another conversation")
        expect(lastOrigin==origin,"background action dispatch retains the original conversation ID")
        expect(queryCount==1 && model.requests.count==modelCount,"cancel/navigation checks do not replay providers or models")
        print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"failures":failures,"actual_assistant_conversation":true,"device_actions":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        if !failures.isEmpty {exit(1)}
    }
}
