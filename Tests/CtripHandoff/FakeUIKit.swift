import Foundation
@MainActor final class UIPasteboard {
    static let general=UIPasteboard()
    var allowWrite=true
    private(set) var writes=0
    private var stored:String?
    var string:String? {
        get { stored }
        set { writes += 1; if allowWrite { stored=newValue } }
    }
    func reset() { allowWrite=true;writes=0;stored=nil }
}
struct HandoffTestOpenOptionsKey:Hashable { static let universalLinksOnly=Self() }
@MainActor final class UIApplication {
    static let shared=UIApplication()
    var appAvailable=true
    var specificAccepted=true
    var generalAccepted=true
    var holdSpecific=false
    var holdGeneral=false
    private var pendingSpecific:CheckedContinuation<Bool,Never>?
    private var pendingGeneral:CheckedContinuation<Bool,Never>?
    private var specificWaiter:CheckedContinuation<Void,Never>?
    private var generalWaiter:CheckedContinuation<Void,Never>?
    private(set) var events=[String]()
    private(set) var universalOnly=[Bool]()
    private(set) var clipboardPreparedAtOpen=[Bool]()
    private(set) var clipboardPreparedAtAvailability=false
    func canOpenURL(_ url:URL)->Bool { events.append("canOpenGeneral");clipboardPreparedAtAvailability=UIPasteboard.general.writes==1 && UIPasteboard.general.string != nil;return appAvailable && url.scheme=="ctrip" }
    func open(_ url:URL,options:[HandoffTestOpenOptionsKey:Any]=[:]) async -> Bool {
        let specific=options[.universalLinksOnly] as? Bool == true
        universalOnly.append(specific)
        clipboardPreparedAtOpen.append(UIPasteboard.general.writes==1 && UIPasteboard.general.string != nil)
        events.append(specific ? "specific" : "general")
        if specific {
            if holdSpecific {
                return await withCheckedContinuation { pendingSpecific=$0;specificWaiter?.resume();specificWaiter=nil }
            }
            return specificAccepted
        }
        if holdGeneral { return await withCheckedContinuation { pendingGeneral=$0;generalWaiter?.resume();generalWaiter=nil } }
        return generalAccepted && url.scheme=="ctrip"
    }
    func waitForSpecific() async { if pendingSpecific != nil { return };await withCheckedContinuation { specificWaiter=$0 } }
    func waitForGeneral() async { if pendingGeneral != nil { return };await withCheckedContinuation { generalWaiter=$0 } }
    func resumeSpecific(_ value:Bool) { let c=pendingSpecific;pendingSpecific=nil;c?.resume(returning:value) }
    func resumeGeneral(_ value:Bool) { let c=pendingGeneral;pendingGeneral=nil;c?.resume(returning:value) }
    func reset() { appAvailable=true;specificAccepted=true;generalAccepted=true;holdSpecific=false;holdGeneral=false;events=[];universalOnly=[];clipboardPreparedAtOpen=[];clipboardPreparedAtAvailability=false }
}
