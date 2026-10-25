import Foundation
@main struct AtomicHandoffChecks {
    @MainActor static var checks=[[String:Any]]()
    @MainActor static var receipts=[[String:Any]]()
    @MainActor static func check(_ name:String,_ passed:Bool) { checks.append(["name":name,"passed":passed]) }
    @MainActor static func reset() { UIApplication.shared.reset();UIPasteboard.general.reset() }
    @MainActor static func fixture(specific:Bool=true,schedule:Bool=false)->(PhoneAgentViewModel,CtripFlightOffer,CtripFlightHandoffOrigin) {
        let vm=PhoneAgentViewModel()
        let offer=CtripFlightOffer(id:"selection",title:"CA1234",details:"出发日期：2026-10-26\n出发时间：08:00\n到达时间：11:00\n出发机场：北京首都 T3\n到达机场：深圳宝安 T3\n舱位：经济舱\n乘客：1位成人\n计价单位：1人/单程\n价格：CNY 600/人（不含税）",price:"CNY 600",bookingURL:specific ? URL(string:"https://flights.ctrip.com/booking/detail?flightno=CA1234") : nil,query:"查询2026年10月26日北京到深圳1名成人经济舱",queriedAt:Date(timeIntervalSince1970:0),referenceOnly:schedule ? true:nil)
        var message=AssistantMessage(role:"assistant",text:"");message.flightOffers=[offer]
        vm.conversation.messages=[message]
        let origin=CtripFlightHandoffOrigin(conversationID:vm.conversation.currentConversationID,messageID:message.id)
        return (vm,offer,origin)
    }
    @MainActor static func settled(_ origin:CtripFlightHandoffOrigin) async {
        for _ in 0..<10000 {
            await Task.yield()
            if let r=CtripFlightHandoffCoordinator.shared.lastReceipt,r.origin==origin,r.stage == .finished,!CtripFlightHandoffCoordinator.shared.isRunning { return }
        }
        check("operation completed",false)
    }
    @MainActor static func record(_ name:String) -> CtripFlightHandoffReceipt {
        let r=CtripFlightHandoffCoordinator.shared.lastReceipt!
        receipts.append(["case":name,"stage":r.stage.rawValue,"clipboard":r.clipboard.rawValue,"specific":r.specificEntry.rawValue,"general":r.generalEntry.rawValue,"outcome":r.outcome.rawValue])
        return r
    }
    @MainActor static func main() async throws {
        reset()
        do {
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);await settled(origin)
            let r=record("specific accepted")
            check("specific success prepares and verifies clipboard first",UIPasteboard.general.writes==1 && UIPasteboard.general.string==o.bookingSummary && r.clipboard == .prepared)
            check("clipboard is already prepared when specific entry is attempted",UIApplication.shared.clipboardPreparedAtOpen==[true])
            check("receipt contains no clipboard or URL payload",Set(Mirror(reflecting:r).children.compactMap(\.label)).isSubset(of:["origin","isSchedule","stage","clipboard","specificEntry","generalEntry","outcome"]))
            check("specific accepted only universal entry with no fallback",UIApplication.shared.events==["specific"] && UIApplication.shared.universalOnly==[true] && r.outcome == .specificAccepted && r.specificEntry == .accepted && r.generalEntry == .notAttempted)
            check("success notice is short and does not assert prefill or order",vm.notice=="航班信息已复制，请在携程核对并选票" && !vm.notice.contains("CA1234") && !vm.notice.contains("订单"))
        }
        reset()
        do {
            UIApplication.shared.specificAccepted=false
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);await settled(origin)
            let r=record("specific failed then general accepted")
            check("specific failure falls back once after copy",UIPasteboard.general.writes==1 && UIApplication.shared.events==["specific","canOpenGeneral","general"] && r.outcome == .generalAccepted && r.specificEntry == .failed && r.generalEntry == .accepted)
            check("both specific and fallback only follow verified copy",UIApplication.shared.clipboardPreparedAtOpen==[true,true])
            check("generic fallback is not universal or browser",UIApplication.shared.universalOnly==[true,false])
        }
        reset()
        do {
            UIApplication.shared.appAvailable=false
            let (vm,o,origin)=fixture(specific:false);vm.bookFlight(o,origin:origin);await settled(origin)
            let r=record("app unavailable")
            check("no app still copies the selected information",UIPasteboard.general.writes==1 && UIPasteboard.general.string==o.bookingSummary && r.clipboard == .prepared)
            check("app availability is checked after copy",UIApplication.shared.clipboardPreparedAtAvailability)
            check("no app opens nothing and reports unavailable",UIApplication.shared.events==["canOpenGeneral"] && r.generalEntry == .unavailable && r.outcome == .unavailable && vm.notice.contains("已复制"))
        }
        reset()
        do {
            UIPasteboard.general.allowWrite=false
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);await settled(origin)
            let r=record("clipboard failed")
            check("clipboard verification failure prevents all opens",r.clipboard == .failed && r.outcome == .failed && UIApplication.shared.events.isEmpty)
            check("failed copy never reports copied",!vm.notice.contains("已复制"))
        }
        reset()
        do {
            UIApplication.shared.holdSpecific=true
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);vm.bookFlight(o,origin:origin)
            await UIApplication.shared.waitForSpecific()
            for _ in 0..<1000 { if CtripFlightHandoffCoordinator.shared.lastReceipt?.outcome == .busy { break };await Task.yield() }
            let busy=record("duplicate tap busy")
            check("double tap receives busy without reentering clipboard or open",busy.outcome == .busy && UIPasteboard.general.writes==1 && UIApplication.shared.events==["specific"])
            UIApplication.shared.resumeSpecific(true);await settled(origin)
            check("first tap completes and releases singleflight",record("first after duplicate").outcome == .specificAccepted && !CtripFlightHandoffCoordinator.shared.isRunning)
        }
        reset()
        do {
            UIApplication.shared.holdSpecific=true
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);await UIApplication.shared.waitForSpecific()
            check("intermediate receipt distinguishes prepared clipboard",CtripFlightHandoffCoordinator.shared.lastReceipt?.clipboard == .prepared && CtripFlightHandoffCoordinator.shared.lastReceipt?.outcome == .clipboardPrepared && CtripFlightHandoffCoordinator.shared.lastReceipt?.stage == .specificEntry)
            vm.conversation.currentConversationID=UUID();vm.notice="new chat unchanged"
            UIApplication.shared.resumeSpecific(false);await settled(origin)
            let r=record("conversation changed during specific")
            check("origin change after specific failure stops generic fallback",r.outcome == .originChanged && r.clipboard == .prepared && UIApplication.shared.events==["specific"])
            check("origin change cannot write notice to new conversation",vm.notice=="new chat unchanged")
        }
        reset()
        do {
            UIApplication.shared.holdSpecific=true
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);await UIApplication.shared.waitForSpecific()
            vm.conversation.messages[0].flightOffers=[];vm.notice=""
            UIApplication.shared.resumeSpecific(false);await settled(origin)
            check("same-chat source offer removal also stops fallback and notice",record("offer removed").outcome == .originChanged && UIApplication.shared.events==["specific"] && vm.notice.isEmpty)
        }
        reset()
        do {
            UIApplication.shared.holdSpecific=true
            let (vm,o,origin)=fixture();vm.bookFlight(o,origin:origin);await UIApplication.shared.waitForSpecific()
            vm.conversation.currentConversationID=UUID();vm.notice="new chat unchanged"
            UIApplication.shared.resumeSpecific(true);await settled(origin)
            let r=record("conversation changed after OS acceptance")
            check("OS acceptance remains recorded without cross-chat success notice",r.outcome == .originChanged && r.specificEntry == .accepted && vm.notice=="new chat unchanged")
        }
        #if CTRIP_CHAT_VISIBILITY_GUARD
        reset()
        do {
            UIApplication.shared.holdSpecific=true
            let (vm,o,origin)=fixture()
            var pageEpoch=UUID()
            let clickedEpoch=pageEpoch
            vm.bookFlight(o,origin:origin,isVisible:{clickedEpoch==pageEpoch})
            await UIApplication.shared.waitForSpecific()
            pageEpoch=UUID()
            vm.notice="new page unchanged"
            UIApplication.shared.resumeSpecific(false);await settled(origin)
            check("leaving chat invalidates pending fallback at unchanged conversation",record("chat page epoch changed").outcome == .originChanged && UIApplication.shared.events==["specific"] && vm.notice=="new page unchanged")
            check("returning without resetting epoch cannot revive old handoff",clickedEpoch != pageEpoch && !CtripFlightHandoffCoordinator.shared.isRunning)
        }
        #endif
        reset()
        do {
            UIApplication.shared.generalAccepted=false
            let (vm,o,origin)=fixture(specific:false);vm.bookFlight(o,origin:origin);await settled(origin)
            let r=record("generic open failed")
            check("copy success and open failure remain separate",r.clipboard == .prepared && r.generalEntry == .failed && r.outcome == .failed && vm.notice.contains("已复制") && vm.notice.contains("无法打开"))
        }
        reset()
        do {
            UIApplication.shared.holdGeneral=true
            let (vm,o,origin)=fixture(specific:false);vm.bookFlight(o,origin:origin);await UIApplication.shared.waitForGeneral()
            vm.conversation.currentConversationID=UUID();vm.notice="new chat unchanged"
            UIApplication.shared.resumeGeneral(true);await settled(origin)
            let r=record("conversation changed during generic")
            check("generic result cannot publish into new chat",r.generalEntry == .accepted && r.outcome == .originChanged && vm.notice=="new chat unchanged")
        }
        reset()
        do {
            let (vm,o,origin)=fixture();vm.conversation.currentConversationID=UUID();vm.notice="new chat unchanged"
            vm.bookFlight(o,origin:origin)
            check("stale clicked origin rejected before clipboard",record("initial stale origin").outcome == .originChanged && UIPasteboard.general.writes==0 && UIApplication.shared.events.isEmpty && vm.notice=="new chat unchanged")
        }
        reset()
        do {
            let (vm,o,origin)=fixture();var changed=o;changed.price="CNY 700"
            vm.bookFlight(changed,origin:origin)
            check("same ID with changed offer cannot snapshot",record("offer mismatch").outcome == .originChanged && UIPasteboard.general.writes==0 && UIApplication.shared.events.isEmpty)
        }
        reset()
        do {
            let (vm,o,origin)=fixture(schedule:true);vm.bookFlight(o,origin:origin);await settled(origin)
            let r=record("schedule reference")
            check("schedule cannot use a booking URL",r.specificEntry == .notAttempted && UIApplication.shared.events==["canOpenGeneral","general"] && vm.notice=="参考时刻已复制，请在携程查价并核对航班")
        }
        reset()
        do {
            let (vm,o,origin)=fixture();var unsafe=o;unsafe.bookingURL=URL(string:"https://example.com/booking/detail?flightno=CA1234")
            vm.conversation.messages[0].flightOffers=[unsafe];vm.bookFlight(unsafe,origin:origin);await settled(origin)
            check("unvalidated source link is never opened",record("unsafe link").specificEntry == .notAttempted && UIApplication.shared.events==["canOpenGeneral","general"])
        }
        let toolText="来源：携程官方查询\n### CA1234\n- 出发日期：2026-10-26\n- 出发时间：08:00\n- 到达时间：11:00\n- 出发机场：北京首都 T3\n- 到达机场：深圳宝安 T3\n- 舱位：经济舱\n- 乘客：1位成人\n- 计价单位：1人/单程\n- 价格：CNY 600/人（不含税）\n- 预订链接：https://flights.ctrip.com/booking/detail?flightno=CA1234"
        let goal="查询2026年10月26日北京到深圳机票"
        let date=Date(timeIntervalSince1970:0)
        let taskOffer=CtripFlightParser.offers(toolText,query:goal,at:date).first!
        reset()
        do {
            let vm=PhoneAgentViewModel(),id=UUID();vm.history.records=[HandoffTestRecord(id:id,goal:goal,updatedAt:date,logs:[HandoffTestLog(title:"工具回执",detail:toolText)])]
            let origin=CtripFlightHandoffOrigin(conversationID:vm.conversation.currentConversationID,taskID:id)
            vm.bookFlight(taskOffer,taskID:id,conversationID:origin.conversationID,isVisible:{true});await settled(origin)
            check("visible historical task card works without chat message link",record("explicit historical task").outcome == .specificAccepted && UIPasteboard.general.writes==1)
        }
        reset()
        do {
            let vm=PhoneAgentViewModel(),id=UUID();vm.history.records=[HandoffTestRecord(id:id,goal:goal,updatedAt:date,logs:[HandoffTestLog(title:"工具回执",detail:toolText)])]
            vm.bookFlight(taskOffer)
            check("legacy call cannot scan arbitrary task history",UIPasteboard.general.writes==0 && UIApplication.shared.events.isEmpty)
            vm.unifiedFocusedTaskID=id
            let origin=CtripFlightHandoffOrigin(conversationID:vm.conversation.currentConversationID,taskID:id)
            vm.bookFlight(taskOffer);await settled(origin)
            check("legacy one-argument call supports explicitly focused task",record("legacy focused task").outcome == .specificAccepted)
        }
        reset()
        do {
            UIApplication.shared.holdSpecific=true
            let vm=PhoneAgentViewModel(),id=UUID();vm.history.records=[HandoffTestRecord(id:id,goal:goal,updatedAt:date,logs:[HandoffTestLog(title:"工具回执",detail:toolText)])]
            let origin=CtripFlightHandoffOrigin(conversationID:vm.conversation.currentConversationID,taskID:id)
            var visible=true
            vm.bookFlight(taskOffer,taskID:id,conversationID:origin.conversationID,isVisible:{visible});await UIApplication.shared.waitForSpecific()
            visible=false;vm.notice="new page unchanged";UIApplication.shared.resumeSpecific(false);await settled(origin)
            check("leaving visible task stops fallback and notice",record("task page left").outcome == .originChanged && UIApplication.shared.events==["specific"] && vm.notice=="new page unchanged")
        }
        let passed=checks.filter { $0["passed"] as? Bool == true }.count
        let result:[String:Any]=["passed":passed,"total":checks.count,"checks":checks,"receipts":receipts,"production_methods_extracted":true,"real_clipboard_or_app_api_called":false]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data("\n".utf8))
        if passed != checks.count { Foundation.exit(1) }
    }
}
