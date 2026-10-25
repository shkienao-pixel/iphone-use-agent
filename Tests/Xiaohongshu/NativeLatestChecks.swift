import Foundation

/// Exercises the production collector/source/store path with the native result
/// layout. These are synthetic pixels, not evidence of device acceptance.
@MainActor final class XHSLatestReplay: XiaohongshuCollectionDriving {
    let inner = XHSNativeReplay()
    var pixels = "valid"
    var hideAfterScroll = false
    var scrolls = 0
    var cardLimit = 3
    init() {
        inner.english = true
        inner.ids = ["5123456789abcdef01234567", "6123456789abcdef01234567", "7123456789abcdef01234567"]
    }
    func resultFrame() -> XiaohongshuCollectionFrame {
        var e = [inner.e("search", "Search", 0.81, 0.085, 0.11), inner.e("query", "人工智能", 0.13, 0.085, 0.25),
            inner.e("all", "All", 0.04, 0.135, 0.04), inner.e("users", "Users", 0.18, 0.135, 0.10),
            inner.e("products", "Products", 0.32, 0.135, 0.16), inner.e("images", "Images", 0.53, 0.135, 0.13),
            inner.e("ai-body", "人工智能是计算机科学的一个分支", 0.05, 0.35, 0.80),
            inner.e("ai-footer", "ai answered for you", 0.06, 0.605, 0.30)]
        e += [inner.e("top", "Top", 0.05, 0.663, 0.06), inner.e("latest", "Latest", 0.16, 0.663, 0.10)]
        for index in 0..<cardLimit {
            e.append(inner.e("card.\(index)", "人工智能真实笔记候选 \(index)", index % 2 == 0 ? 0.03 : 0.54, index < 2 ? 0.76 : 0.88, 0.40))
        }
        for i in e.indices { e[i].rect.height = 0.016 }
        if pixels == "duplicate" { var duplicate = e.first { $0.id == "latest" }!; duplicate.id = "duplicate-latest"; e.append(duplicate) }
        if pixels == "wrong-row", let i = e.firstIndex(where: { $0.id == "latest" }) { e[i].rect.y += 0.1 }
        if pixels == "wrong-query", let i = e.firstIndex(where: { $0.id == "query" }) { e[i].label = "错误关键词" }
        if pixels == "model-source", let i = e.firstIndex(where: { $0.id == "all" }) { e[i].source = "model" }
        if pixels == "merged-all", let i = e.firstIndex(where: { $0.id == "all" }) { e[i].label = "AIl =" }
        if pixels == "merged-sort", let i = e.firstIndex(where: { $0.id == "latest" }) { e[i].label = "Top Latest" }
        if pixels == "upper-row" {
            for i in e.indices where ["top", "latest"].contains(e[i].id) { e[i].rect.y = 0.185 }
            e.removeAll { ["ai-body", "ai-footer"].contains($0.id) }
        }
        if pixels == "explicit" {
            for i in e.indices where ["all", "latest"].contains(e[i].id) { e[i].label += " (Selected)" }
        }
        if hideAfterScroll && scrolls > 0 { e.removeAll { ["top", "latest"].contains($0.id) } }
        let snapshot = PhoneUISnapshot(deviceKey:"native-source-device", scene:"untrusted", elements:e, capturedAt:Date())
        let hash = String(repeating:"d",count:64)
        var evidence = XiaohongshuPageAdapter.localSelectionEvidence(snapshot:snapshot,screenshotSHA256:hash) { x,y in
            guard self.pixels != "missing" && self.pixels != "explicit" else { return nil }
            let shade = self.pixels == "flat-chip" ? 0.12 : 0.035
            let black = XiaohongshuPixel(red:shade,green:shade,blue:shade)
            let gray = XiaohongshuPixel(red:0.34,green:0.34,blue:0.34)
            let white = XiaohongshuPixel(red:0.80,green:0.80,blue:0.80)
            for id in ["all","top","latest"] {
                guard let element = e.first(where:{$0.id==id}) else {continue}
                if x >= element.rect.x && x <= element.rect.x + element.rect.width && y >= element.rect.y && y <= element.rect.y + element.rect.height {
                    if id == "all" {return self.pixels == "dim-all" ? gray : white}
                    if id == "top" {return ["both-white","top-selected"].contains(self.pixels) ? white : gray}
                    return self.pixels == "dim-latest" || self.pixels == "top-selected" ? gray : white
                }
            }
            if let all = e.first(where:{$0.id=="all"}), self.pixels != "no-underline",
               x >= all.rect.x - 0.008 && x <= all.rect.x + all.rect.width + 0.008,
               abs(y - all.rect.y - all.rect.height - 0.008) <= 0.0015 {return .init(red:1,green:0.08,blue:0.22)}
            if let latest = e.first(where:{$0.id=="latest"}), self.pixels != "no-chip",
               x >= latest.rect.x && x <= latest.rect.x + latest.rect.width &&
               y >= latest.rect.y - 0.010 && y <= latest.rect.y + latest.rect.height + 0.010 {return .init(red:0.12,green:0.12,blue:0.12)}
            return black
        }
        if pixels == "stale-time" { for i in evidence.indices {evidence[i].capturedAt = Date().addingTimeInterval(-5)} }
        if pixels == "wrong-peer" { for i in evidence.indices where evidence[i].method == .nativeLatestContrastChip {evidence[i].peerElementID="query"} }
        let frame = XiaohongshuCollectionFrame(snapshot:snapshot,shareID:inner.shareID,width:1320,height:2868,
            selectionEvidence:evidence,screenshotSHA256:pixels == "stale-hash" ? String(repeating:"e",count:64) : hash,confirmedAt:Date())
        inner.last = frame
        return frame
    }
    func read() async throws -> XiaohongshuCollectionFrame {
        if inner.mode == .results {return resultFrame()}
        var frame = try await inner.read(); frame.width = 1320; frame.height = 2868; inner.last = frame; return frame
    }
    func openNote(_ element:PhoneUIElement) async throws {try await inner.openNote(element)}
    func returnToResults() async throws {try await inner.returnToResults()}
    func scrollResults(at element: PhoneUIElement) async throws {scrolls += 1}
    func tapObserved(_ element:PhoneUIElement) async throws {try await inner.tapObserved(element)}
    func clipboardSnapshot(readText:Bool) async throws -> XiaohongshuClipboardSnapshot {try await inner.clipboardSnapshot(readText:readText)}
    func resolveShortLink(_ url:URL) async throws -> XiaohongshuResolvedLink {try await inner.resolveShortLink(url)}
}

@MainActor enum XHSNativeLatestChecks {
    static func run(folder:URL) async throws -> Int {
        var count=0
        func expect(_ value:Bool,_ label:String) {precondition(value,label);count += 1}
        func task(_ suffix:String) -> XiaohongshuCollectionTask {.init(id:"latest-"+suffix,keyword:"人工智能",sampleSize:3,sort:"最新")}
        func store(_ suffix:String) -> XiaohongshuCollectionStore {.init(url:folder.appendingPathComponent("latest-"+suffix+".json"))}
        let replay=XHSLatestReplay(), frame=replay.resultFrame()
        expect(XiaohongshuPageAdapter.identity(in:frame.snapshot)?.scene=="xiaohongshu.results","All/Users/Products/Images and native chips identify results without a fabricated Filter label")
        expect(frame.selectionEvidence.contains{$0.method == .neutralTextAndRedUnderline && $0.elementID=="all"},"All selected evidence needs actual neutral text plus its red underline")
        expect(frame.selectionEvidence.contains{$0.method == .nativeLatestContrastChip && $0.peerElementID=="top"},"Latest selected evidence compares its actual chip/foreground with the unique same-row Top peer")
        expect(XiaohongshuPageAdapter.sortKey("All")=="all" && XiaohongshuPageAdapter.sortKey("Top")=="top","Neither All nor Top is invented as general sort")
        expect(XiaohongshuCollector.scopeEvidence(task:task("scope"),frame:frame)==["query","all","latest"],"Query, All category and native Latest sort have independent scope evidence")
        let upper=XHSLatestReplay();upper.pixels="upper-row"
        expect(XiaohongshuCollector.scopeEvidence(task:task("upper"),frame:upper.resultFrame()) != nil,"Same-row native chips use geometry relative to All instead of a fixed first-screenshot vertical position")
        let candidates=XiaohongshuCollector.candidates(in:frame.snapshot,task:task("scope"))
        expect(candidates.count==3 && candidates.allSatisfy{$0.id.hasPrefix("card.")},"AI body/footer and sort chips are excluded; only candidates below the actual sort row remain")
        let disk=store("full")
        let run=try await XiaohongshuCollector(store:disk).collect(task:task("full"),driver:replay)
        expect(run.status == .sampleReached && run.notes.count==3 && Set(run.notes.map(\.id)).count==3,"Three native Latest samples require three real source IDs through production collect/share/copy/store")
        expect(replay.inner.copyTaps==3 && replay.inner.filterOpens==0 && replay.inner.returns==2,"Native sort proof does not tap a guessed Filter or select Top")
        expect(run.pages.allSatisfy{$0.scopeVersion==3},"Native All/Latest proof has its own archive scope version")
        expect(try run.statistics().conditionEvidence=="native_all_category_and_latest_sort_verified_from_current_pixels","Export statistics distinguish the exact native scope proof")
        expect(try XiaohongshuCollectionStore(url:folder.appendingPathComponent("latest-full.json")).run(id:run.id)?.notes.count==3,"Native pixel scope validates again after loading the actual saved document")
        for variant in ["missing","no-underline","dim-all","dim-latest","top-selected","both-white","no-chip","flat-chip","stale-hash","stale-time","wrong-peer","duplicate","wrong-row","wrong-query","model-source","merged-all","merged-sort","explicit"] {
            let invalid=XHSLatestReplay();invalid.pixels=variant
            let result=try await XiaohongshuCollector(store:store(variant)).collect(task:task(variant),driver:invalid)
            expect(result.status == .paused && result.notes.isEmpty && invalid.inner.noteOpens==0,"Missing/ambiguous/wrong native evidence refuses all input: "+variant)
        }
        var general=task("general");general.sort="综合"
        expect(XiaohongshuCollector.scopeEvidence(task:general,frame:frame)==nil,"Native Latest cannot satisfy a requested general sort")
        var filtered=task("filtered");filtered.filters=["All"]
        expect(XiaohongshuCollector.scopeEvidence(task:filtered,frame:frame)==nil,"All category does not satisfy an extra filter; native path only supports filters empty")
        let hidden=XHSLatestReplay();hidden.cardLimit=1;hidden.hideAfterScroll=true
        let hiddenRun=try await XiaohongshuCollector(store:store("hidden")).collect(task:task("hidden"),driver:hidden)
        expect(hiddenRun.status == .paused && hiddenRun.notes.count==1 && hidden.inner.copyTaps==1,"Leaving the sort bar offscreen stops after saved notes instead of authorizing from an old screenshot")
        for version in [1,2] {
            var downgraded=run;downgraded.pages[0].scopeVersion=version
            var rejected=false;do{try downgraded.validate()}catch{rejected=true}
            expect(rejected,"New native proof cannot remove the All requirement by downgrading scope to \(version)")
            let invalidURL=folder.appendingPathComponent("native-downgrade-\(version).json")
            let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(downgraded))
            let bytes=try JSONSerialization.data(withJSONObject:["version":1,"runs":[object]])
            try bytes.write(to:invalidURL)
            let invalidStore=XiaohongshuCollectionStore(url:invalidURL)
            expect(invalidStore.error != nil,"Loading a complete downgraded native document refuses it")
            expect(try Data(contentsOf:invalidURL)==bytes,"Rejected native downgrade preserves its original document")
        }
        var missingProof=run;missingProof.pages[0].selectionEvidence=[]
        var missingRejected=false;do{try missingProof.validate()}catch{missingRejected=true}
        expect(missingRejected,"A scope version 3 document without native pixels cannot claim strict scope")

        // Start from the real legacy filter-menu production transaction, then
        // retain additional unselected OCR labels that coincidentally have the
        // new native row geometry. These labels were legal in old documents.
        let oldDriver=XHSNativeReplay();oldDriver.english=true
        let oldTask=XiaohongshuCollectionTask(id:"legacy-geometry-source",keyword:"人工智能",sampleSize:1)
        let oldRun=try await XiaohongshuCollector(store:store("legacy-source")).collect(task:oldTask,driver:oldDriver)
        expect(oldRun.pages[0].scopeVersion==2 && oldRun.pages[0].scopeCapture != nil,"Legacy compatibility fixture starts with actual old sort/filter scope proof")
        let extras=frame.snapshot.elements.filter{["all","products","images","top","latest"].contains($0.id)}
        for version in [1,2] {
            var legacyRun=oldRun;legacyRun.task.id="legacy-geometry-v\(version)"
            legacyRun.pages[0].elements += extras
            legacyRun.pages[0].elementCount=legacyRun.pages[0].elements.count
            let oldSnapshot=PhoneUISnapshot(deviceKey:"stored-page",scene:"xiaohongshu.results",elements:legacyRun.pages[0].elements,capturedAt:legacyRun.pages[0].observedAt)
            legacyRun.pages[0].viewport=XiaohongshuCollector.viewport(oldSnapshot)
            legacyRun.checkpoint?.viewport=legacyRun.pages[0].viewport
            if var capture=legacyRun.pages[0].scopeCapture {
                capture.resultsBefore.snapshot.elements += extras
                capture.resultsAfter.snapshot.elements += extras
                legacyRun.pages[0].scopeCapture=capture
                legacyRun.checkpoint?.scopeCapture=capture
            }
            expect(XiaohongshuPageAdapter.nativeLatestLayout(in:oldSnapshot) != nil,"Old OCR really overlaps the native geometry; this is not only an optional-field decode test")
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacyRun)) as! [String:Any]
            if version==1 {
                var pages=object["pages"] as! [[String:Any]]
                for key in ["scopeVersion","scopeCapture","selectionEvidence","screenshotSHA256"] {pages[0].removeValue(forKey:key)}
                object["pages"]=pages
                if var checkpoint=object["checkpoint"] as? [String:Any] {checkpoint.removeValue(forKey:"scopeCapture");object["checkpoint"]=checkpoint}
            }
            let url=folder.appendingPathComponent("legacy-native-geometry-v\(version).json")
            let bytes=try JSONSerialization.data(withJSONObject:["version":1,"runs":[object]])
            try bytes.write(to:url)
            let loaded=XiaohongshuCollectionStore(url:url)
            expect(loaded.error==nil,"A complete legitimate old v\(version) document with native-like OCR remains readable")
            let restored=try loaded.run(id:legacyRun.id)!
            expect(restored.notes.count==1 && restored.pages[0].scopeVersion==version,"Old source-backed notes and original scope version are preserved")
            expect(!restored.pages[0].selectionEvidence.contains{$0.method == .neutralTextAndRedUnderline || $0.method == .nativeLatestContrastChip},"The migration does not invent new native pixel proof")
            let statistics=try restored.statistics()
            expect(statistics.conditionEvidence.contains("legacy") && statistics.conditionEvidence != "native_all_category_and_latest_sort_verified_from_current_pixels","Old scopes are not retroactively certified as native All/Latest")
            let exported=try JSONSerialization.jsonObject(with:loaded.export(id:restored.id)) as! [String:Any]
            let stats=exported["recomputedStatistics"] as! [String:Any]
            expect(stats["uniqueSamples"] as? Int==1 && (stats["conditionEvidence"] as? String)?.contains("legacy")==true,"Production export recomputes old sample count and explicitly preserves the scope gap")
            expect(try Data(contentsOf:url)==bytes,"Loading and exporting an old archive does not silently rewrite it")
            try loaded.save(restored)
            expect(try XiaohongshuCollectionStore(url:url).run(id:restored.id)?.pages[0].scopeVersion==version,"The old document remains readable after an explicit production save and reload")
        }
        let legacy=frame.selectionEvidence.first{$0.method == .nativeLatestContrastChip}!
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
        for key in ["neutralTextSamples","underlineFraction","peerElementID","textLuminance","peerTextLuminance","chipBackgroundSamples","chipContrast"] {object.removeValue(forKey:key)}
        object["method"]="redTextAndUnderline"
        let decoded=try JSONDecoder().decode(XiaohongshuSelectionEvidence.self,from:JSONSerialization.data(withJSONObject:object))
        expect(decoded.neutralTextSamples==nil && decoded.peerElementID==nil,"Old selection evidence without new optional fields still decodes")
        return count
    }
}
