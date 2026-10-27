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
    enum State { case active, inactive, background }
    var applicationState = State.active
    var appAvailable=true
    var specificAccepted=true
    var specificResponses=[Bool]()
    var generalAccepted=true
    var holdSpecific=false
    var holdGeneral=false
    private var pendingSpecific:CheckedContinuation<Bool,Never>?
    private var pendingGeneral:CheckedContinuation<Bool,Never>?
    private var specificWaiter:CheckedContinuation<Void,Never>?
    private var generalWaiter:CheckedContinuation<Void,Never>?
    private(set) var events=[String]()
    private(set) var universalOnly=[Bool]()
    private(set) var openedURLs=[URL]()
    private(set) var availabilityURLs=[URL]()
    private(set) var clipboardPreparedAtOpen=[Bool]()
    private(set) var clipboardPreparedAtAvailability=false
    func canOpenURL(_ url:URL)->Bool {
        events.append(url.path=="/flight_inquire" ? "canOpenGeneral" : "canOpenSpecific")
        availabilityURLs.append(url)
        clipboardPreparedAtAvailability=UIPasteboard.general.writes==1 && UIPasteboard.general.string != nil
        return appAvailable && url.scheme=="ctrippro" && url.host=="wireless"
    }
    func open(_ url:URL,options:[HandoffTestOpenOptionsKey:Any]=[:]) async -> Bool {
        let universal=options[.universalLinksOnly] as? Bool == true
        let specific=universal || (url.scheme=="ctrippro" && ["/flight_inland_singlelist", "/flight_inland_singletransition"].contains(url.path))
        universalOnly.append(universal)
        openedURLs.append(url)
        clipboardPreparedAtOpen.append(UIPasteboard.general.writes==1 && UIPasteboard.general.string != nil)
        events.append(specific ? "specific" : "general")
        if specific {
            if holdSpecific {
                return await withCheckedContinuation { pendingSpecific=$0;specificWaiter?.resume();specificWaiter=nil }
            }
            return specificResponses.isEmpty ? specificAccepted : specificResponses.removeFirst()
        }
        if holdGeneral { return await withCheckedContinuation { pendingGeneral=$0;generalWaiter?.resume();generalWaiter=nil } }
        return generalAccepted && url.scheme=="ctrippro" && url.host=="wireless" && url.path=="/flight_inquire"
    }
    func waitForSpecific() async { if pendingSpecific != nil { return };await withCheckedContinuation { specificWaiter=$0 } }
    func waitForGeneral() async { if pendingGeneral != nil { return };await withCheckedContinuation { generalWaiter=$0 } }
    func resumeSpecific(_ value:Bool) { let c=pendingSpecific;pendingSpecific=nil;c?.resume(returning:value) }
    func resumeGeneral(_ value:Bool) { let c=pendingGeneral;pendingGeneral=nil;c?.resume(returning:value) }
    func reset() { applicationState = .active;appAvailable=true;specificAccepted=true;specificResponses=[];generalAccepted=true;holdSpecific=false;holdGeneral=false;events=[];universalOnly=[];openedURLs=[];availabilityURLs=[];clipboardPreparedAtOpen=[];clipboardPreparedAtAvailability=false }
}
