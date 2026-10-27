import Foundation
import Combine

@MainActor final class LookupGate {
    var calls = [String]()
    var hold = false
    var fails = false
    var response = ""
    private var pending: CheckedContinuation<String, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func query(_ text: String) async throws -> String {
        calls.append(text)
        if fails { throw AgentError.message("offline query failed") }
        if hold { return try await withCheckedThrowingContinuation { pending = $0; waiter?.resume(); waiter = nil } }
        return response
    }
    func wait() async { if pending != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func resume() { let value = pending; pending = nil; value?.resume(returning: response) }
}

@main struct AtomicHandoffChecks {
    @MainActor static var checks = [[String: Any]]()
    @MainActor static var receipts = [[String: Any]]()
    @MainActor static func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    @MainActor static func reset() { UIApplication.shared.reset(); UIPasteboard.general.reset() }
    @MainActor static func fixture(missingTime: Bool = false, dated: Bool = true, schedule: Bool = false) -> (PhoneAgentViewModel, CtripFlightOffer, CtripFlightHandoffOrigin) {
        let vm = PhoneAgentViewModel()
        let details = (dated ? "出发日期：2026-10-30\n" : "") + (missingTime ? "" : "出发时间：07:05\n") + "到达时间：09:05\n出发机场：深圳宝安 T3\n到达机场：武汉天河 T3\n航程类型：直飞\n舱位：经济舱\n乘客：1位成人\n计价单位：1人/单程"
        let offer = CtripFlightOffer(id: "selection", title: "HU7779", details: details, price: "350元", bookingURL: URL(string: "https://flights.ctrip.com/booking/detail?flightno=HU7779"), query: dated ? "查询2026-10-30深圳到武汉单程，1位成人经济舱" : "查询深圳到武汉单程，1位成人经济舱", queriedAt: Date(timeIntervalSince1970: 0), referenceOnly: schedule ? true : nil)
        var message = AssistantMessage(role: "assistant", text: ""); message.flightOffers = [offer]
        vm.conversation.messages = [message]
        return (vm, offer, .init(conversationID: vm.conversation.currentConversationID, messageID: message.id))
    }
    static var response: String {
        "来源：携程官方查询\n### HU7779\n出发日期：2026-10-30\n出发时间：07:05\n到达时间：09:05\n出发机场：深圳宝安国际机场 T3\n到达机场：武汉天河国际机场 T3\n航程类型：直飞\n舱位：经济舱\n价格：368元（不含税）"
    }
    @MainActor static func install(_ vm: PhoneAgentViewModel, response text: String = response) -> LookupGate {
        let gate = LookupGate(); gate.response = text
        vm.conversation.flightQuery = { try await gate.query($0) }; return gate
    }
    @MainActor static func settled(_ origin: CtripFlightHandoffOrigin) async {
        for _ in 0..<10000 {
            await Task.yield()
            if let receipt = CtripFlightHandoffCoordinator.shared.lastReceipt, receipt.origin == origin,
               receipt.stage == .finished, !CtripFlightHandoffCoordinator.shared.isRunning { return }
        }
        check("operation completed", false)
    }
    @MainActor static func record(_ name: String) -> CtripFlightHandoffReceipt {
        let r = CtripFlightHandoffCoordinator.shared.lastReceipt!
        receipts.append(["case": name, "stage": r.stage.rawValue, "clipboard": r.clipboard.rawValue,
            "specific": r.specificEntry.rawValue, "general": r.generalEntry.rawValue, "outcome": r.outcome.rawValue])
        return r
    }
    @MainActor static func exactOnly(_ name: String) {
        check(name + ": no list, home or HTTPS fallback", UIApplication.shared.openedURLs.allSatisfy {
            $0.scheme == "ctrippro" && $0.host == "wireless" && $0.path == "/flight_inland_singletransition"
        } && !UIApplication.shared.events.contains("canOpenGeneral") && !UIApplication.shared.events.contains("general"))
    }
    @MainActor static func main() async throws {
        #if DEBUG
        runCtripDebugCaptureChecks { name, passed in check(name, passed) }
        #endif
        reset()
        do {
            let (vm, offer, origin) = fixture(), gate = install(vm)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            let r = record("complete exact card")
            check("complete card does not requery", gate.calls.isEmpty)
            check("complete card opens only its selected native entry", UIApplication.shared.openedURLs == [offer.preferredNativeFlightSelectionURL!] && r.outcome == .specificAccepted && r.generalEntry == .notAttempted)
            check("selected clipboard prepared once before open", UIPasteboard.general.writes == 1 && UIPasteboard.general.string == offer.bookingSummary && UIApplication.shared.clipboardPreparedAtOpen == [true])
            check("OS acceptance notice makes no arrival claim", vm.notice == "已向携程发送打开这班航班选价页的请求，请核对实际页面")
            check("receipt contains only bounded outcome fields", Set(Mirror(reflecting: r).children.compactMap(\.label)).isSubset(of: ["origin", "isSchedule", "stage", "clipboard", "specificEntry", "generalEntry", "outcome", "selectionDiagnostic"]) && r.selectionDiagnostic == "source_exact_entry_ready")
            exactOnly("complete card")
        }
        reset()
        do {
            UIApplication.shared.specificAccepted = false
            let (vm, offer, origin) = fixture(); vm.bookFlight(offer, origin: origin); await settled(origin)
            check("failed exact selection never becomes list success", record("exact open rejected").outcome == .failed && UIApplication.shared.openedURLs == [offer.preferredNativeFlightSelectionURL!])
            check("failure notice does not claim copied-only completion", vm.notice.contains("未能打开这班航班") && !vm.notice.contains("已复制"))
            exactOnly("rejected exact entry")
        }
        reset()
        do {
            let (vm, offer, origin) = fixture(dated: false), gate = install(vm)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("missing absolute date cannot trigger a guessed query", gate.calls.isEmpty && record("no date anchor").outcome == .missingInformation)
            check("source HTTPS cannot replace a selected-flight entry", offer.flightSpecificBookingURL != nil && UIApplication.shared.openedURLs.isEmpty && UIPasteboard.general.writes == 0)
        }
        reset()
        do {
            UIPasteboard.general.allowWrite = false
            let (vm, offer, origin) = fixture(); vm.bookFlight(offer, origin: origin); await settled(origin)
            check("clipboard failure prevents every app call", record("clipboard failed").clipboard == .failed && UIApplication.shared.events.isEmpty && !vm.notice.contains("已复制"))
        }
        reset()
        do {
            UIApplication.shared.appAvailable = false
            let (vm, offer, origin) = fixture(); vm.bookFlight(offer, origin: origin); await settled(origin)
            check("missing Lite only checks exact entry availability", record("Lite missing").outcome == .failed && UIApplication.shared.openedURLs.isEmpty && UIApplication.shared.events == ["canOpenSpecific"])
            exactOnly("Lite missing")
        }
        reset()
        do {
            UIApplication.shared.holdSpecific = true
            let (vm, offer, origin) = fixture(); vm.bookFlight(offer, origin: origin); await UIApplication.shared.waitForSpecific()
            vm.bookFlight(offer, origin: origin)
            for _ in 0..<1000 { if CtripFlightHandoffCoordinator.shared.lastReceipt?.outcome == .busy { break }; await Task.yield() }
            check("duplicate card tap shares one operation", record("duplicate exact tap").outcome == .busy && UIPasteboard.general.writes == 1 && UIApplication.shared.openedURLs.count == 1)
            UIApplication.shared.resumeSpecific(true); await settled(origin)
            check("singleflight released", record("first exact completes").outcome == .specificAccepted && !CtripFlightHandoffCoordinator.shared.isRunning)
        }
        for changed in ["conversation", "offer", "sourceText", "page", "presentation", "message", "background"] {
            reset()
            UIApplication.shared.holdSpecific = true
            let (vm, offer, origin) = fixture(); var visible = true
            vm.bookFlight(offer, origin: origin, isVisible: { visible }); await UIApplication.shared.waitForSpecific()
            switch changed {
            case "conversation": vm.conversation.currentConversationID = UUID()
            case "offer": vm.conversation.messages[0].flightOffers = []
            case "sourceText": vm.conversation.messages[0].text += "来源更正"
            case "page": visible = false
            case "presentation": vm.conversation.flightOpeningPresentationRevision = UUID()
            case "message": vm.conversation.messages.append(.init(role: "user", text: "改日期"))
            default: UIApplication.shared.applicationState = .background
            }
            vm.notice = "new context unchanged"; UIApplication.shared.resumeSpecific(false); await settled(origin)
            check("pending exact open respects changed " + changed, record("changed " + changed).outcome == .originChanged && UIApplication.shared.openedURLs.count == 1 && vm.notice == "new context unchanged")
            exactOnly("changed " + changed)
        }
        reset()
        do {
            let (vm, offer, origin) = fixture(); vm.conversation.currentConversationID = UUID(); vm.notice = "new context unchanged"
            vm.bookFlight(offer, origin: origin)
            check("stale source rejected before any action", record("stale click").outcome == .originChanged && UIApplication.shared.events.isEmpty && UIPasteboard.general.writes == 0 && vm.notice == "new context unchanged")
        }
        reset()
        do {
            UIApplication.shared.applicationState = .inactive
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("inactive app cannot begin lookup", gate.calls.isEmpty && UIApplication.shared.events.isEmpty && UIPasteboard.general.writes == 0 && record("inactive click").outcome == .originChanged)
        }
        reset()
        do {
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            let r = record("missing time supplemented")
            check("one logical query supplements missing clock", gate.calls.count == 1 && gate.calls[0].contains("HU7779") && gate.calls[0].contains("2026-10-30") && gate.calls[0].contains("SZX") && gate.calls[0].contains("WUH"))
            check("supplement uses newly returned fare in clipboard", r.outcome == .specificAccepted && UIPasteboard.general.string?.contains("368元") == true && UIPasteboard.general.string?.contains("07:05") == true)
            check("original source remains immutable", vm.conversation.messages[0].flightOffers == [offer])
            check("active lookup completion replaces its progress with the accepted-request notice", !vm.notice.contains("正在补查") && vm.notice.contains("已向携程发送"))
            check("only native target opened after supplementation", UIApplication.shared.openedURLs.count == 1 && UIApplication.shared.openedURLs[0].absoluteString.contains("flight_inland_singletransition"))
            exactOnly("supplemented clock")
        }
        for exit in ["external-open", "guard-lookup", "new-notice", "same-new-notice", "reentrant-same-notice", "new-notice-active", "same-new-notice-active"] {
            reset()
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm)
            gate.hold = true
            UIApplication.shared.holdSpecific = exit == "external-open" || exit.hasSuffix("-active")
            let progress = "正在补查这班航班的信息"
            var reentered = false
            var observer: AnyCancellable?
            if exit == "reentrant-same-notice" {
                observer = vm.$notice.dropFirst().sink { value in
                    if value == progress && !reentered { reentered = true; vm.notice = progress }
                }
            }
            vm.bookFlight(offer, origin: origin); await gate.wait()
            check("held lookup publishes its progress: " + exit, vm.notice == progress)
            if exit == "external-open" {
                gate.resume(); await UIApplication.shared.waitForSpecific()
                UIApplication.shared.applicationState = .background
                UIApplication.shared.resumeSpecific(true); await settled(origin)
                let receipt = record("lookup external open")
                check("accepted external open keeps its origin guard and clears only its own lookup progress", receipt.outcome == .originChanged && receipt.specificEntry == .accepted && vm.notice.isEmpty && !CtripFlightHandoffCoordinator.shared.isRunning && UIApplication.shared.openedURLs.count == 1)
            } else if exit.hasSuffix("-active") {
                gate.resume(); await UIApplication.shared.waitForSpecific()
                let newer = exit == "same-new-notice-active" ? progress : "new operation on the same page"
                vm.notice = newer
                UIApplication.shared.resumeSpecific(true); await settled(origin)
                check("completion cannot overwrite a newer notice while the original page stays current: " + exit, record(exit).outcome == .specificAccepted && vm.notice == newer && UIApplication.shared.openedURLs.count == 1 && !CtripFlightHandoffCoordinator.shared.isRunning)
            } else {
                vm.conversation.flightOpeningPresentationRevision = UUID()
                if exit == "new-notice" { vm.notice = "new page operation notice" }
                if exit == "same-new-notice" { vm.notice = progress }
                gate.resume(); await settled(origin)
                let expected = exit == "guard-lookup" ? "" : exit == "new-notice" ? "new page operation notice" : progress
                check("guard completion respects progress ownership: " + exit, record(exit).outcome == .originChanged && vm.notice == expected && UIApplication.shared.openedURLs.isEmpty && UIPasteboard.general.writes == 0 && !CtripFlightHandoffCoordinator.shared.isRunning)
            }
            observer?.cancel()
        }
        for missing in ["舱位：经济舱", "航程类型：直飞"] {
            reset()
            let (vm, original, origin) = fixture(); var offer = original; offer.details = offer.details.replacingOccurrences(of: missing, with: "")
            vm.conversation.messages[0].flightOffers = [offer]; let gate = install(vm)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("supplement missing " + missing, gate.calls.count == 1 && record("missing " + missing).outcome == .specificAccepted && UIApplication.shared.openedURLs.count == 1)
        }
        reset()
        do {
            let (vm, offer, origin) = fixture(schedule: true), gate = install(vm)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("reference timetable must obtain a real quote before opening", gate.calls.count == 1 && record("reference repriced").outcome == .specificAccepted && UIPasteboard.general.string?.contains("368元") == true)
        }
        let rejected: [(String, String)] = [
            ("different flight", response.replacingOccurrences(of: "HU7779", with: "HU7712")),
            ("different date", response.replacingOccurrences(of: "2026-10-30", with: "2026-10-31")),
            ("different source city", response.replacingOccurrences(of: "深圳宝安国际机场 T3", with: "上海虹桥 T3")),
            ("different destination city", response.replacingOccurrences(of: "武汉天河国际机场 T3", with: "北京大兴 T3")),
            ("still no departure time", response.replacingOccurrences(of: "出发时间：07:05\n", with: "")),
            ("no returned airports", response.replacingOccurrences(of: "出发机场：深圳宝安国际机场 T3\n到达机场：武汉天河国际机场 T3\n", with: "")),
            ("no direct confirmation", response.replacingOccurrences(of: "航程类型：直飞\n", with: "")),
            ("no cabin confirmation", response.replacingOccurrences(of: "舱位：经济舱\n", with: "")),
            ("wrong known arrival clock", response.replacingOccurrences(of: "09:05", with: "09:30")),
            ("no real quote", response.replacingOccurrences(of: "价格：368元（不含税）", with: "价格：待核实")),
            ("duplicate matching flights", response + "\n" + response),
            ("empty result", "没有可用的航班结果")
        ]
        for (name, text) in rejected {
            reset()
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm, response: text)
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("bounded lookup rejects " + name, gate.calls.count == 1 && record(name).outcome == .missingInformation && UIPasteboard.general.writes == 0 && UIApplication.shared.events.isEmpty)
            check("rejected lookup has a bounded diagnostic: " + name, record(name).selectionDiagnostic != nil && record(name).selectionDiagnostic!.count < 80)
        }
        reset()
        do {
            let (vm, original, origin) = fixture(); var offer = original; offer.details = offer.details.replacingOccurrences(of: "舱位：经济舱", with: "舱位：待核实")
            vm.conversation.messages[0].flightOffers = [offer]
            let gate = install(vm, response: response.replacingOccurrences(of: "07:05", with: "08:05"))
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("known source clock cannot be replaced during missing-cabin lookup", gate.calls.count == 1 && record("known clock conflict").outcome == .missingInformation && UIPasteboard.general.writes == 0 && UIApplication.shared.events.isEmpty)
        }
        reset()
        do {
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm); gate.fails = true
            vm.bookFlight(offer, origin: origin); await settled(origin)
            check("query error cannot loop or degrade to copying", gate.calls.count == 1 && record("lookup error").outcome == .lookupFailed && UIPasteboard.general.writes == 0 && UIApplication.shared.events.isEmpty)
            check("lookup failure replaces its own progress with the terminal failure", vm.notice == "补查这班航班失败，请稍后重试")
        }
        reset()
        do {
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm); gate.hold = true
            vm.bookFlight(offer, origin: origin); await gate.wait(); vm.bookFlight(offer, origin: origin)
            for _ in 0..<1000 { if CtripFlightHandoffCoordinator.shared.lastReceipt?.outcome == .busy { break }; await Task.yield() }
            check("busy lease covers the query itself", record("duplicate during query").outcome == .busy && gate.calls.count == 1 && UIPasteboard.general.writes == 0)
            gate.resume(); await settled(origin)
            check("first query proceeds to exact native selection", record("first query completed").outcome == .specificAccepted && gate.calls.count == 1 && UIApplication.shared.openedURLs.count == 1)
        }
        for changed in ["conversation", "offer", "sourceText", "page", "presentation", "message", "background", "background-return"] {
            reset()
            let (vm, offer, origin) = fixture(missingTime: true), gate = install(vm); gate.hold = true; var visible = true
            vm.bookFlight(offer, origin: origin, isVisible: { visible }); await gate.wait()
            switch changed {
            case "conversation": vm.conversation.currentConversationID = UUID()
            case "offer": vm.conversation.messages[0].flightOffers = []
            case "sourceText": vm.conversation.messages[0].text += "来源更正"
            case "page": visible = false
            case "presentation": vm.conversation.flightOpeningPresentationRevision = UUID()
            case "message": vm.conversation.messages.append(.init(role: "user", text: "改成北京"))
            case "background-return": UIApplication.shared.applicationState = .active; vm.conversation.flightOpeningPresentationRevision = UUID()
            default: UIApplication.shared.applicationState = .background
            }
            vm.notice = "new context unchanged"; gate.resume(); await settled(origin)
            check("lookup result cannot revive changed " + changed, record("query changed " + changed).outcome == .originChanged && gate.calls.count == 1 && UIPasteboard.general.writes == 0 && UIApplication.shared.events.isEmpty && vm.notice == "new context unchanged")
        }
        for accepted in [true, false] {
            reset()
            let (vm, original, origin) = fixture(); var selected = original
            var provider = URLComponents(url: original.reconstructedNativeFlightSelectionURL!, resolvingAgainstBaseURL: false)!
            provider.queryItems!.append(.init(name: "providerMarker", value: "offline-fixture")); selected.bookingURL = provider.url
            vm.conversation.messages[0].flightOffers = [selected]
            UIApplication.shared.specificResponses = accepted ? [true] : [false, true]
            vm.bookFlight(selected, origin: origin); await settled(origin)
            check("provider exact URL retains priority \(accepted)", UIApplication.shared.openedURLs.first == provider.url)
            check("provider failure may try only independent same-flight native entry \(accepted)", UIApplication.shared.openedURLs == (accepted ? [provider.url!] : [provider.url!, selected.reconstructedNativeFlightSelectionURL!]) && record("provider \(accepted)").outcome == .specificAccepted && UIPasteboard.general.writes == 1)
            exactOnly("provider \(accepted)")
        }
        reset()
        do {
            let vm = PhoneAgentViewModel(), id = UUID()
            let goal = "2026-10-30深圳到武汉单程经济舱"
            vm.history.records = [.init(id: id, goal: goal, updatedAt: Date(timeIntervalSince1970: 0), logs: [.init(title: "工具回执", detail: response)])]
            let offer = CtripFlightParser.offers(response, query: goal, at: Date(timeIntervalSince1970: 0))[0]
            vm.bookFlight(offer)
            check("legacy entry never scans arbitrary history", UIPasteboard.general.writes == 0 && UIApplication.shared.events.isEmpty)
            vm.unifiedFocusedTaskID = id
            let origin = CtripFlightHandoffOrigin(conversationID: vm.conversation.currentConversationID, taskID: id)
            vm.bookFlight(offer); await settled(origin)
            check("explicitly focused task still opens its exact flight", record("focused task").outcome == .specificAccepted && UIApplication.shared.openedURLs == [offer.preferredNativeFlightSelectionURL!])
        }
        let passed = checks.filter { $0["passed"] as? Bool == true }.count
        let result: [String: Any] = ["passed": passed, "total": checks.count, "checks": checks, "receipts": receipts,
            "production_methods_extracted": true, "real_clipboard_or_app_api_called": false]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        if passed != checks.count { Foundation.exit(1) }
    }
}
