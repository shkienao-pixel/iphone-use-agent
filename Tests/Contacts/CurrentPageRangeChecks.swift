import Foundation

/// Real production navigation/Reader/Store/Summarizer with synthetic local
/// observations and an echo-only model closure. No phone, private chat or API.
enum CurrentPageRangeChecks {
    @MainActor static func run(folder: URL) async throws -> Int {
        var checks = 0, actual: [[String: Any]] = []
        func expect(_ value: Bool, _ text: String) { checks += 1; precondition(value, text) }
        func record(_ row: [String: Any], evidence: URL? = nil) throws {
            actual.append(row)
            guard let path = ProcessInfo.processInfo.environment["CHAT_CURRENT_PAGE_REPORT"] else { return }
            let report = URL(fileURLWithPath:path)
            try JSONSerialization.data(withJSONObject:["offlineOnly":true,"actual":actual],options:[.prettyPrinted,.sortedKeys]).write(to:report,options:.atomic)
            if let evidence, let name = row["case"] as? String {
                let output = report.deletingLastPathComponent().appendingPathComponent("after-evidence")
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                try Data(contentsOf:evidence).write(to:output.appendingPathComponent(name+".json"),options:.atomic)
            }
        }
        struct Document: Codable { var version = 1; var sessions: [ChatEvidenceSession] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let target = ChatConversationTarget(stableID:"wechat.builtin.file-transfer",title:"文件传输助手",deviceKey:"synthetic-fixture-device")
        // Only this assertion-side oracle knows the unseen latest messages.
        let oracle = (1...9).map { String(format:"Synthetic Record%03d",$0) }
        let middle = Array(oracle[2..<5]), latestOracle = Array(oracle.suffix(3))
        for limit in [0,201] {
            let invalid = ChatReadRequest(scopeID:"invalid-page-limit-\(limit)",conversation:target,range:.currentPage(limit:limit),maxPages:1)
            let invalidStore = ChatEvidenceStore(url:folder.appendingPathComponent("invalid-limit-\(limit).json"))
            var rejected = false, reads = 0
            do { _ = try await ChatEvidenceReader(store:invalidStore).read(request:invalid,nextFrame:{reads += 1; throw ChatEvidenceError.invalidFrame},scroll:{_ in preconditionFailure("No invalid-scope input")}) } catch ChatEvidenceError.invalidRequest { rejected = true }
            expect(rejected && reads == 0 && invalidStore.sessions.isEmpty,"Invalid current-page bounds cannot authorize a read or create a scope")
        }
        var pixel = Date(timeIntervalSince1970:1_800_000_000)
        func element(_ id:String,_ text:String,_ x:Double,_ y:Double,_ width:Double=0.18,source:String="ocr") -> PhoneUIElement {
            .init(id:id,label:text,rect:.init(x:x-width/2,y:y-0.015,width:width,height:0.03),source:source)
        }
        func observe(_ elements:[PhoneUIElement],stream:UUID) -> WeChatConversationObservation {
            pixel = pixel.addingTimeInterval(1)
            return .init(snapshot:.init(deviceKey:target.deviceKey,scene:"untrusted scene",elements:elements,capturedAt:pixel),captureSessionID:stream,frameID:UUID().uuidString)
        }
        func profile(stream:UUID,account:String="filehelper") -> WeChatConversationObservation {
            observe([element("profile-name",target.title,0.358,0.146,0.287),
                element("profile-account","Weixin ID: "+account,0.388,0.178,0.347),
                element("description-1","Transfer text, images, audio and video files",0.587,0.273,0.738),
                element("description-2","between your device and your PC",0.508,0.293,0.581),
                element("messages","Messages",0.502,0.357,0.247),
                element("back-visual","视觉:返回",0.09,0.08,0.04,source:"local_visual"),
                element("more-visual","视觉:更多",0.91,0.08,0.06,source:"local_visual")],stream:stream)
        }
        func chat(_ texts:[String],stream:UUID) -> WeChatConversationObservation {
            observe([element("back","微信",0.1,0.08),element("title",target.title,0.5,0.08),element("input","发送消息",0.4,0.9)] +
                texts.enumerated().map { element("bubble-\($0.offset)",$0.element,0.75,0.32+Double($0.offset)*0.07) },stream:stream)
        }
        // Same production identity fixtures as the immutable before audit;
        // visual labels are synthetic I/O here, not a new pixel-detection claim.
        let failedURL = folder.appendingPathComponent("old-empty-stopped-latest.json"), failedStore = ChatEvidenceStore(url:failedURL)
        let failedRequest = ChatReadRequest(scopeID:"old-empty-stopped-latest",conversation:target,range:.latest(count:3),maxPages:1)
        var oldFailure = ChatEvidenceSession(request:failedRequest)
        oldFailure.state = .stopped; oldFailure.detail = "旧版本已停止：资料账号未通过，未读取消息"
        oldFailure.updatedAt = Date(timeIntervalSince1970:1_700_000_000)
        try failedStore.save(oldFailure)
        let failedBytes = try Data(contentsOf:failedURL)
        var failedReads = 0, failedBlocked = false
        do { _ = try await ChatEvidenceReader(store:failedStore).read(request:failedRequest,nextFrame:{failedReads += 1; throw ChatEvidenceError.invalidFrame},scroll:{_ in preconditionFailure("No latest input")}) } catch ChatEvidenceError.latestEndUnknown { failedBlocked = true }
        let failedAfter = try failedStore.session(id:oldFailure.id)
        try record(["case":"old-empty-stopped-latest","beforeState":oldFailure.state.rawValue,"afterState":failedAfter.state.rawValue,"reads":failedReads,"bytesUnchanged":try Data(contentsOf:failedURL) == failedBytes],evidence:failedURL)
        expect(try failedBlocked && failedReads == 0 && failedAfter == oldFailure && Data(contentsOf:failedURL) == failedBytes,"A rejected latest retry preserves even an empty old stopped/detail/timestamp checkpoint exactly")
        let failedRetry = ContactCaptureFixture([profile(stream:UUID()),chat(latestOracle,stream:UUID())])
        var failedDriverBlocked = false
        do { _ = try await failedRetry.driver.read(request:failedRequest,store:failedStore) } catch ChatEvidenceError.latestEndUnknown { failedDriverBlocked = true }
        expect(try failedDriverBlocked && failedRetry.reads == 0 && failedRetry.taps.isEmpty && failedStore.session(id:oldFailure.id) == oldFailure && Data(contentsOf:failedURL) == failedBytes,"Driver also preserves an empty historical failure without reading or navigating")
        for state in [ChatReadState.reading,.partial,.complete] {
            let name = "old-empty-\(state.rawValue)", path = folder.appendingPathComponent("old-empty-\(state.rawValue).json")
            let archive = ChatEvidenceStore(url:path)
            var old = oldFailure; old.request.scopeID = name; old.state = state
            try archive.save(old); let bytes = try Data(contentsOf:path)
            var rejected = false
            do { _ = try await ChatEvidenceReader(store:archive).read(request:old.request,nextFrame:{preconditionFailure("No old latest read")},scroll:{_ in preconditionFailure("No old latest input")}) } catch ChatEvidenceError.latestEndUnknown { rejected = true }
            expect(try rejected && archive.session(id:name) == old && Data(contentsOf:path) == bytes,"Every existing empty latest state retains its original detail/timestamp/bytes")
        }
        for (name,page) in [("latest-middle",middle),("latest-oracle-position",latestOracle)] {
            let stream = UUID(), tape = ContactCaptureFixture([profile(stream:stream),chat(page,stream:stream)])
            let url = folder.appendingPathComponent(name+".json"), store = ChatEvidenceStore(url:url)
            let request = ChatReadRequest(scopeID:name,conversation:target,range:.latest(count:3),maxPages:3)
            var blocked = false, calls = 0
            do { _ = try await tape.driver.read(request:request,store:store) } catch ChatEvidenceError.latestEndUnknown { blocked = true }
            let session = try store.session(id:name)
            do { _ = try await ChatEvidenceSummarizer { _ in calls += 1; return "{\"claims\":[]}" }.summarize(sessionID:name,store:store) } catch ChatEvidenceError.latestEndUnknown { }
            try record(["case":name,"state":session.state.rawValue,"selected":session.selectedMessages.count,"reads":tape.reads,"taps":tape.taps.count,"scrolls":tape.scrolls.count,"modelCalls":calls],evidence:url)
            expect(blocked && session.state == .partial && session.detail.contains("latestEndUnknown") && session.selectedMessages.isEmpty,"No observable newest endpoint means latest is partial/unknown even if the oracle happens to be newest")
            expect(tape.reads == 0 && tape.taps.isEmpty && tape.scrolls.isEmpty && calls == 0,"Unsupported latest performs no profile navigation, page read or model call")
        }

        var baseline: ChatEvidenceSession?, baselineStore: ChatEvidenceStore?, baselineURL: URL?
        for limit in [2,3,5] {
            let stream = UUID(), name = "current-page-\(limit)"
            let tape = ContactCaptureFixture([profile(stream:stream),chat(middle,stream:stream),chat(latestOracle,stream:stream)])
            let url = folder.appendingPathComponent(name+".json"), store = ChatEvidenceStore(url:url)
            let request = ChatReadRequest(scopeID:name,conversation:target,range:.currentPage(limit:limit),maxPages:1)
            let session = try await tape.driver.read(request:request,store:store)
            let expected = Array(middle.suffix(limit))
            var modelCalls = 0, promptTexts: [String] = []
            let summarizer = ChatEvidenceSummarizer { prompt in
                modelCalls += 1
                let payload = try JSONSerialization.jsonObject(with:Data(prompt.components(separatedBy:"原消息数据：\n").last!.utf8)) as! [String:Any]
                let messages = payload["messages"] as! [[String:Any]]
                promptTexts = messages.map { $0["text"] as! String }
                let claims: [[String:Any]] = messages.map {
                    ["category":"fact","statement":$0["text"]!,"citations":[["messageID":$0["id"]!,"quote":$0["text"]!]],"owner":NSNull(),"deadline":NSNull()]
                }
                return String(decoding:try JSONSerialization.data(withJSONObject:["claims":claims]),as:UTF8.self)
            }
            let report = try await summarizer.summarize(sessionID:name,store:store)
            let summarized = try store.session(id:name), bytes = try Data(contentsOf:url)
            try record(["case":name,"state":session.state.rawValue,"observed":session.messages.count,"selected":session.selectedMessages.count,"selectedTexts":session.selectedMessages.map{$0.observation.text},"reads":tape.reads,"taps":tape.taps,"scrolls":tape.scrolls.count,"modelCalls":modelCalls,"promptTexts":promptTexts,"oracleLatestMatch":expected == latestOracle],evidence:url)
            expect(session.state == .complete && session.messages.count == 3 && session.selectedMessages.map{$0.observation.text} == expected,"Explicit current-page sample has honest observed/selected counts and preserves visible order")
            expect(tape.reads == 2 && tape.taps == ["messages"] && tape.scrolls.isEmpty && tape.observations.count == 1,"Profile → one current Messages tap → first chat page never consumes the unseen next page")
            expect(session.frames.count == 1 && session.frames[0].conversation.kind == .contactProfileNavigation && session.frames[0].conversation.contactNavigation?.profile.account == "filehelper","Current-page range still requires independent reserved identity/navigation proof")
            expect(session.messages.allSatisfy{$0.observation.platformMessageID == nil} && session.unmergedBatches == nil,"No synthetic platform IDs or new cross-page authority is created")
            expect(session.pageSelection?.messageIDs == session.selectedMessages.map(\.id) && session.pageSelection?.frameID == session.frames[0].id,"Immutable selection binds exact accepted-frame message IDs")
            expect(modelCalls == 1 && promptTexts == expected && report.messageIDs == session.selectedMessages.map(\.id),"Only explicitly selected first-page rows reach the injected model")
            expect(report.warnings.contains{$0.contains("首个可见页")} && report.claims.count == min(limit,3) && expected != latestOracle,"Current-page report discloses sample scope without claiming latest-end correctness")
            expect(try ChatEvidenceStore(url:url).session(id:name) == summarized,"Complete profile/navigation/page selection/report checkpoint reopens exactly")
            for direction in [ChatReadDirection.older,.newer] {
                let retry = ContactCaptureFixture([profile(stream:UUID()),chat(latestOracle,stream:UUID())])
                var rejected = false
                do { _ = try await retry.driver.read(request:request,store:store,direction:direction) } catch { rejected = true }
                expect(rejected && retry.reads == 0 && retry.taps.isEmpty && retry.scrolls.isEmpty,"Bound current-page scope cannot resume, navigate or widen in either direction")
                expect(try store.session(id:name) == summarized && Data(contentsOf:url) == bytes,"Rejected reread leaves the entire bound checkpoint unchanged")
            }
            var directReads = 0, directBlocked = false
            do { _ = try await ChatEvidenceReader(store:store).read(request:request,nextFrame:{ directReads += 1; throw ChatEvidenceError.invalidFrame },scroll:{_ in preconditionFailure("No scroll")}) } catch ChatEvidenceError.pageAlreadyBound { directBlocked = true }
            expect(directBlocked && directReads == 0,"Reader boundary independently rejects same-scope page rebinding")
            _ = try await summarizer.summarize(sessionID:name,store:store)
            expect(modelCalls == 1,"Unchanged explicitly selected current-page v2 evidence may reuse saved segments")
            if limit == 2 { baseline = try store.session(id:name); baselineStore = store; baselineURL = url }
        }

        let good = baseline!, store = baselineStore!, url = baselineURL!, goodBytes = try Data(contentsOf:url)
        func rejects(_ label:String,_ mutate:(inout ChatEvidenceSession)->Void) throws {
            var invalid = good; mutate(&invalid)
            var failed = false; do { try store.save(invalid) } catch { failed = true }
            expect(try failed && store.session(id:good.id) == good && Data(contentsOf:url) == goodBytes,"Rejected selection edit preserves memory/disk: \(label)")
            let badURL = folder.appendingPathComponent("invalid-page-\(checks).json"), bytes = try encoder.encode(Document(sessions:[invalid]))
            try bytes.write(to:badURL)
            let reopened = ChatEvidenceStore(url:badURL)
            expect(try !reopened.error.isEmpty && Data(contentsOf:badURL) == bytes,"Persisted malformed selection fails closed without rewriting: \(label)")
        }
        try rejects("unknown version") { $0.pageSelection!.version = 2 }
        try rejects("missing selection") { $0.pageSelection = nil }
        try rejects("mixed scope") { $0.pageSelection!.scopeID = "another-current-page" }
        try rejects("mixed target") { $0.pageSelection!.requestedConversation.stableID = "wechat.account:other" }
        try rejects("mixed target title") { $0.pageSelection!.requestedConversation.title = "同名另一人" }
        try rejects("mixed target device") { $0.pageSelection!.requestedConversation.deviceKey = "other" }
        try rejects("missing frame") { $0.pageSelection!.frameID = "missing" }
        try rejects("pixel clock changed") { $0.pageSelection!.capturedAt = $0.pageSelection!.capturedAt.addingTimeInterval(1) }
        try rejects("limit changed") { $0.pageSelection!.limit = 3 }
        try rejects("duplicate IDs") { $0.pageSelection!.messageIDs = [$0.messages[1].id,$0.messages[1].id] }
        try rejects("wrong order") { $0.pageSelection!.messageIDs.reverse() }
        try rejects("unknown ID") { $0.pageSelection!.messageIDs[0] = "missing" }
        try rejects("outside bound suffix") { $0.pageSelection!.messageIDs = [$0.messages[0].id,$0.messages[1].id] }
        try rejects("partial omitted ID") { $0.pageSelection!.messageIDs.removeLast() }
        try rejects("accepted row order changed") { $0.messages.swapAt(0,1) }
        try rejects("extra accepted page") { var second = $0.frames[0]; second.id = "different-frame"; $0.frames.append(second) }
        try rejects("observations changed") { $0.messages[0].observation.text += " changed" }
        try rejects("current selection on legacy latest") { $0.request.range = .latest(count:2); $0.reports = []; $0.summaries = [] }
        try rejects("report includes observed but unselected row") { $0.reports[0].messageIDs = $0.messages.map(\.id) }
        try rejects("segment cites observed but unselected row") { value in
            let outside = value.messages[0]
            value.summaries[0].messageIDs = [outside.id]; value.summaries[0].contextMessageIDs = []
            value.summaries[0].claims = [.init(category:.fact,statement:outside.observation.text,citations:[.init(messageID:outside.id,quote:outside.observation.text)])]
            value.reports = []
        }
        try rejects("raw source cannot become selected") { value in
            var rawSnapshot = value.frames[0].snapshot; rawSnapshot.capturedAt = rawSnapshot.capturedAt.addingTimeInterval(1)
            let rawID = "unmerged-raw-page", row = value.frames[0].rows[0]
            var rawRow = row; rawRow.anchor.frameID = rawID; rawRow.anchor.capturedAt = rawSnapshot.capturedAt
            value.unmergedBatches = [.init(id:rawID,snapshot:rawSnapshot,rows:[rawRow],captureSessionID:value.frames[0].captureSessionID,scopeID:value.id,requestedConversation:target,direction:.older,reason:.unverifiedOccurrenceContinuity,sourceFrameID:value.frames[0].id)]
            value.pageSelection!.frameID = rawID
        }
        try rejects("raw message promotion") { value in
            var row = value.messages[0].observation; row.anchor.frameID = "unmerged-raw-page"
            value.messages.append(.init(id:"raw-citation",observation:row,anchors:[row.anchor]))
            value.pageSelection!.messageIDs.append("raw-citation")
        }
        var changedRange = good.request; changedRange.range = .currentPage(limit:3)
        var rangeRejected = false; do { _ = try store.prepare(changedRange) } catch { rangeRejected = true }
        expect(try rangeRejected && Data(contentsOf:url) == goodBytes,"Same scope cannot change the current-page limit or range")

        let legacyFixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-latest-v2.json")
        let legacyURL = folder.appendingPathComponent("legacy-latest-v2.json"), legacyBytes = try Data(contentsOf:legacyFixture)
        try legacyBytes.write(to:legacyURL)
        let legacyStore = ChatEvidenceStore(url:legacyURL), legacy = legacyStore.sessions[0]
        expect(legacy.state == .complete && legacy.reports.count == 1 && legacy.summaries.first?.validationVersion == 2 && legacy.pageSelection == nil,"Real pre-fix synthetic complete/v2 latest checkpoint remains readable")
        expect(legacy.selectedMessages.isEmpty && legacy.isLatestEndUnknown,"Historical count-complete state never supplies new latest-range selection authority")
        try legacyStore.save(legacy)
        expect(try Data(contentsOf:legacyURL) == legacyBytes,"Unchanged legacy latest complete/v2 checkpoint saves byte-identically")
        let exported = try encoder.encode(legacy)
        expect(try JSONDecoder().decode(ChatEvidenceSession.self,from:exported) == legacy,"Legacy raw report and summary export preserves every field")
        expect(legacy.reports[0].markdown().contains("最新端未获独立证明"),"Read-only old report rendering discloses its latest-range limit without mutating fields")
        var legacyModelCalls = 0, legacyRejected = false
        do { _ = try await ChatEvidenceSummarizer {_ in legacyModelCalls += 1; return "{\"claims\":[]}"}.summarize(sessionID:legacy.id,store:legacyStore) } catch ChatEvidenceError.latestEndUnknown { legacyRejected = true }
        let retry = ContactCaptureFixture([profile(stream:UUID()),chat(latestOracle,stream:UUID())])
        var legacyReadRejected = false
        do { _ = try await retry.driver.read(request:legacy.request,store:legacyStore) } catch ChatEvidenceError.latestEndUnknown { legacyReadRejected = true }
        try record(["case":"legacy-latest-v2","historicalState":legacy.state.rawValue,"selected":legacy.selectedMessages.count,"modelCalls":legacyModelCalls,"reads":retry.reads,"bytesUnchanged":try Data(contentsOf:legacyURL) == legacyBytes],evidence:legacyURL)
        expect(legacyRejected && legacyReadRejected && legacyModelCalls == 0 && retry.reads == 0 && retry.taps.isEmpty,"Old v2 reuse and new read both reject before external work")
        expect(try legacyStore.session(id:legacy.id) == legacy && Data(contentsOf:legacyURL) == legacyBytes,"Blocked latest retries leave legacy complete evidence and reports exactly unchanged")
        let wrong = ContactCaptureFixture([profile(stream:UUID(),account:"filehelper_fake")])
        var wrongRejected = false
        do { _ = try await wrong.driver.read(request:.init(scopeID:"wrong-current-identity",conversation:target,range:.currentPage(limit:3),maxPages:1),store:ChatEvidenceStore(url:folder.appendingPathComponent("wrong-current-identity.json"))) } catch { wrongRejected = true }
        expect(wrongRejected && wrong.reads == 1 && wrong.taps.isEmpty && wrong.scrolls.isEmpty,"Explicit current-page mode preserves wrong reserved-account rejection before Messages")
        return checks
    }
}
