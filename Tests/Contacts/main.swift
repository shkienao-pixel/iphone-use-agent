import Foundation

@MainActor final class ContactCaptureFixture {
    var observations: [WeChatConversationObservation]
    var last: WeChatConversationObservation?
    var reads = 0
    var taps: [String] = []
    var scrolls: [ChatReadDirection] = []
    var clock = Date.distantPast
    var failTap = false
    var failScroll = false
    var cancelTap = false
    init(_ observations: [WeChatConversationObservation]) { self.observations = observations }
    func read() throws -> WeChatConversationObservation {
        guard !observations.isEmpty else { throw AgentError.message("fixture exhausted") }
        let next = observations.removeFirst(); last = next; reads += 1
        clock = max(clock, next.confirmedAt ?? next.snapshot.capturedAt).addingTimeInterval(0.1)
        return next
    }
    func tap(_ element: PhoneUIElement) throws {
        guard last?.snapshot.element(id: element.id) == element else { throw AgentError.message("not a current fixture element") }
        taps.append(element.id); clock = clock.addingTimeInterval(0.1)
        if failTap { throw AgentError.message("fixture tap interrupted") }
        if cancelTap { throw CancellationError() }
    }
    func scroll(_ direction: ChatReadDirection) throws {
        scrolls.append(direction)
        if failScroll { throw CancellationError() }
    }
    var driver: WeChatConversationDriver {
        .init(read: self.read, tap: self.tap, scroll: self.scroll, now: { self.clock })
    }
}

@main struct ContactChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        func rejects(_ body: () throws -> Void, _ message: String) { var failed = false; do { try body() } catch { failed = true }; expect(failed, message) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-contact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = "wxid_fixture123", title = "王伟", stream = UUID(), device = "fixture-device"
        let stableID = try WeChatContactIdentity.stableID(account: account)
        let target = ChatConversationTarget(stableID: stableID, title: title, deviceKey: device)
        var time = Date().addingTimeInterval(-1000)
        func element(_ id: String, _ text: String, _ x: Double, _ y: Double, _ width: Double = 0.18) -> PhoneUIElement {
            .init(id: id, label: text, rect: .init(x: x - width / 2, y: y - 0.015, width: width, height: 0.03), source: "ocr")
        }
        func observation(_ elements: [PhoneUIElement], deviceKey: String = "fixture-device", capture: UUID? = nil) -> WeChatConversationObservation {
            time = time.addingTimeInterval(1)
            return .init(snapshot: .init(deviceKey: deviceKey, scene: "unknown", elements: elements, capturedAt: time),
                captureSessionID: capture ?? stream, frameID: UUID().uuidString)
        }
        func profile(account value: String? = nil, title name: String? = nil, split: Bool = false) -> WeChatConversationObservation {
            var elements = [element("back", "通讯录", 0.1, 0.07), element("name", name ?? title, 0.5, 0.18),
                element("moments", "朋友圈", 0.25, 0.48), element("message", "发消息", 0.5, 0.7), element("call", "音视频通话", 0.5, 0.8)]
            if split { elements += [element("account-label", "微信号：", 0.3, 0.25, 0.2), element("account-value", value ?? account, 0.62, 0.25, 0.4)] }
            else { elements.append(element("account", "微信号：" + (value ?? account), 0.55, 0.25, 0.65)) }
            return observation(elements)
        }
        func chat(_ texts: [String], title name: String? = nil, capture: UUID? = nil) -> WeChatConversationObservation {
            var elements = [element("back", "微信", 0.1, 0.08), element("title", name ?? title, 0.5, 0.08), element("input", "发送消息", 0.4, 0.9)]
            elements += texts.enumerated().map { index, text in element("bubble-\(index)", text, 0.75, 0.3 + Double(index) * 0.07) }
            return observation(elements, capture: capture)
        }
        let initialProfile = profile()
        let recognized = try WeChatContactIdentity.profile(snapshot: initialProfile.snapshot, frameID: initialProfile.frameID, captureSessionID: stream, target: target)
        expect(recognized.account == account && recognized.messageElementID == "message", "Actual visible WeChat account and dedicated profile structure identify the authorized contact")
        try recognized.validate(for: target)
        expect(recognized.evidenceElementIDs.count == 6, "Profile proof retains back/name/account/moments/message/call anchors")
        let splitProfile = profile(split: true)
        let splitIdentity = try WeChatContactIdentity.profile(snapshot: splitProfile.snapshot, frameID: splitProfile.frameID, captureSessionID: stream, target: target)
        expect(splitIdentity.evidenceElementIDs.contains("account-label") && splitIdentity.evidenceElementIDs.contains("account-value"), "Split OCR label/value profile keeps both real source anchors")
        expect(try WeChatContactIdentity.account(fromStableID: stableID) == account, "Canonical scope preserves the exact visible account")
        rejects({ _ = try WeChatContactIdentity.account(fromStableID: title) }, "A display name cannot stand in for a stable account scope")
        rejects({ _ = try WeChatContactIdentity.stableID(account: "bad account") }, "Unsupported account syntax is rejected rather than normalized into a different person")
        var wrongTarget = target; wrongTarget.stableID = try WeChatContactIdentity.stableID(account: "wxid_other123")
        rejects({ try recognized.validate(for: wrongTarget) }, "Same display name with a different exact account is rejected")

        for removed in ["account", "moments", "call", "message", "back", "name"] {
            var missing = initialProfile.snapshot; missing.elements.removeAll { $0.id == removed }
            rejects({ _ = try WeChatContactIdentity.profile(snapshot: missing, frameID: initialProfile.frameID, captureSessionID: stream, target: target) }, "Missing \(removed) cannot be replaced with a guessed profile element")
        }
        var duplicate = initialProfile.snapshot; duplicate.elements.append(element("account-other", "微信号：wxid_other123", 0.55, 0.32, 0.65))
        rejects({ _ = try WeChatContactIdentity.profile(snapshot: duplicate, frameID: initialProfile.frameID, captureSessionID: stream, target: target) }, "Conflicting duplicate account fields cannot select a person")
        var duplicateMessage = initialProfile.snapshot; duplicateMessage.elements.append(element("other-message", "发消息", 0.5, 0.6))
        rejects({ _ = try WeChatContactIdentity.profile(snapshot: duplicateMessage, frameID: initialProfile.frameID, captureSessionID: stream, target: target) }, "Ambiguous message controls cannot dispatch a tap")
        var covered = initialProfile.snapshot; covered.blockingOverlay = true
        rejects({ _ = try WeChatContactIdentity.profile(snapshot: covered, frameID: initialProfile.frameID, captureSessionID: stream, target: target) }, "An overlay blocks profile identity proof")
        var unrelated = initialProfile.snapshot; unrelated.elements[unrelated.elements.firstIndex { $0.id == "account" }!].source = "model"
        rejects({ _ = try WeChatContactIdentity.profile(snapshot: unrelated, frameID: initialProfile.frameID, captureSessionID: stream, target: target) }, "Model-authored account text is not real visible profile evidence")

        let firstChat = chat(["A", "B", "张三负责，周五交付", "D"])
        let olderChat = chat(["E", "F", "A", "B"])
        let fixture = ContactCaptureFixture([initialProfile, firstChat, olderChat]), storeURL = directory.appendingPathComponent("contacts.json")
        let store = ChatEvidenceStore(url: storeURL)
        let request = ChatReadRequest(scopeID: "explicit-contact-range", conversation: target, range: .currentPage(limit: 6), maxPages: 1)
        var readAmbiguous = false
        do { _ = try await fixture.driver.read(request: request, store: store) } catch ChatEvidenceError.ambiguousContinuity { readAmbiguous = true }
        let session = try store.session(id: request.scopeID)
        expect(fixture.taps == ["message"] && fixture.scrolls.isEmpty && fixture.reads == 2, "Production current-page driver taps the observed profile once and never reads or scrolls a second page")
        expect(!readAmbiguous && session.state == .complete && session.messages.map { $0.observation.text } == ["A", "B", "张三负责，周五交付", "D"], "Real profile proves the first-page sample without claiming the latest end")
        expect(session.frames[0].conversation.kind == .contactProfileNavigation && session.frames.count == 1 && session.unmergedBatches == nil && session.pageSelection != nil, "Current-page scope binds only the independently identified first frame and does not observe the unused second page")
        expect(session.frames[0].conversation.contactNavigation?.profile.account == account, "Archived first-chat proof contains the exact independently observed account")
        expect(session.frames[0].snapshot.elements.allSatisfy { $0.source == "ocr" }, "No synthetic platform_identity elements are injected into the real screenshot")
        expect(try ChatEvidenceStore(url: storeURL).session(id: request.scopeID) == session, "Profile, input timeline, capture chain and raw chat evidence survive audit on disk reload")
        var modelCalls = 0
        let report = try await ChatEvidenceSummarizer(model: { _ in
            modelCalls += 1
            let message = session.messages.first { $0.observation.text.contains("张三负责") }!
            return "{\"claims\":[{\"category\":\"task\",\"statement\":\"张三周五交付\",\"citations\":[{\"messageID\":\"\(message.id)\",\"quote\":\"张三负责，周五交付\"}],\"owner\":\"张三\",\"deadline\":\"周五\"}]}"
        }).summarize(sessionID: request.scopeID, store: store)
        expect(modelCalls == 1 && report.claims[0].owner == "张三", "Ordinary-contact production evidence reaches the existing strict citation summarizer")
        expect(report.markdown().contains("王伟") && report.messageIDs.count == 4, "Contact report retains the exact scoped conversation and actual evidence count")

        // Starting another run on the existing chat cannot restore account
        // authority from its title or from the prior saved profile evidence.
        let resume = ContactCaptureFixture([chat(["E", "F", "A", "B"])])
        var resumeRejected = false
        do { _ = try await resume.driver.read(request: request, store: store) } catch { resumeRejected = true }
        expect(resumeRejected && resume.taps.isEmpty && resume.scrolls.isEmpty, "Resume from a title-only chat must re-open and prove the personal profile; no input is replayed")
        expect(try store.session(id: request.scopeID).messages.count == 4, "A failed resumed identity check preserves all prior accepted messages")

        let wrongAccount = ContactCaptureFixture([profile(account: "wxid_other123")])
        var wrongRejected = false
        do { _ = try await wrongAccount.driver.bootstrap(target: target) } catch { wrongRejected = true }
        expect(wrongRejected && wrongAccount.taps.isEmpty, "Wrong account with identical display name stops before tapping Send Message")
        let changedTitle = ContactCaptureFixture([profile(), chat(["hello"], title: "另一人")])
        var changedRejected = false
        do { _ = try await changedTitle.driver.open(target: target) } catch { changedRejected = true }
        expect(changedRejected && changedTitle.taps.count == 1, "A changed conversation title after navigation cannot inherit the profile account")
        let changedCapture = ContactCaptureFixture([profile(), chat(["hello"], capture: UUID())])
        var captureRejected = false
        do { _ = try await changedCapture.driver.bootstrap(target: target) } catch { captureRejected = true }
        expect(captureRejected && changedCapture.taps.count == 1, "Capture replacement during profile navigation invalidates identity without retrying the tap")
        var foreignChat = chat(["hello"]); foreignChat.snapshot.deviceKey = "different-device"
        let changedDevice = ContactCaptureFixture([profile(), foreignChat])
        var deviceRejected = false
        do { _ = try await changedDevice.driver.bootstrap(target: target) } catch { deviceRejected = true }
        expect(deviceRejected && changedDevice.taps.count == 1, "A different device after tapping cannot inherit the account binding")
        let interrupted = ContactCaptureFixture([profile(), chat(["hello"])]); interrupted.failTap = true
        var tapFailed = false
        do { _ = try await interrupted.driver.bootstrap(target: target) } catch { tapFailed = true }
        expect(tapFailed && interrupted.taps.count == 1 && interrupted.reads == 1, "Interrupted tap stops immediately, without re-reading or replaying Send Message")
        let cancelled = ContactCaptureFixture([profile(), chat(["hello"])]); cancelled.cancelTap = true
        var cancelFailed = false
        do { _ = try await cancelled.driver.bootstrap(target: target) } catch is CancellationError { cancelFailed = true }
        expect(cancelFailed && cancelled.taps.count == 1 && cancelled.reads == 1, "Cancellation during navigation cannot create conversation proof")
        let transitioning = ContactCaptureFixture([profile(), profile(), chat(["hello"])])
        let transitioned = try await transitioning.driver.bootstrap(target: target)
        expect(transitioning.taps.count == 1 && transitioning.reads == 3 && transitioned.conversation.kind == .contactProfileNavigation, "A slow transition reobserves only the same valid profile without another input")
        let noTransition = ContactCaptureFixture([profile(), profile(), profile(), profile()])
        var timeoutRejected = false
        do { _ = try await noTransition.driver.bootstrap(target: target) } catch { timeoutRejected = true }
        expect(timeoutRejected && noTransition.taps.count == 1 && noTransition.reads == 4, "A profile that never opens chat ends after bounded fresh observations, never repeated taps")

        var forged = session.frames[0]
        forged.conversation.contactNavigation?.profile.account = "wxid_other123"
        rejects({ try forged.validate(for: target) }, "Editing the archived account invalidates the navigation proof on audit")
        forged = session.frames[0]; forged.conversation.contactNavigation?.tapCompletedAt = forged.snapshot.capturedAt.addingTimeInterval(1)
        rejects({ try forged.validate(for: target) }, "A chat frame captured before its alleged navigation completed cannot prove identity")
        let noLeaseAdapter = ChatEvidenceCaptureAdapter()
        rejects({ _ = try noLeaseAdapter.begin(bootstrap: session.frames[0], target: target) }, "Previously stored independent profile evidence cannot restore live navigation authority")
        let freshBootstrap = try await ContactCaptureFixture([profile(), chat(["current"])]).driver.bootstrap(target: target)
        let adapter = ChatEvidenceCaptureAdapter()
        _ = try adapter.begin(bootstrap: freshBootstrap, target: target)
        rejects({ _ = try adapter.begin(bootstrap: freshBootstrap, target: target) }, "A live bootstrap permit seeds a capture adapter once, never resets an active chain")
        let restoredAdapter = ChatEvidenceCaptureAdapter()
        rejects({ _ = try restoredAdapter.begin(bootstrap: session.frames[0], target: target) }, "A stored profile frame cannot restore a consumed live bootstrap permit")

        func visualChat(_ texts: [String]) -> WeChatConversationObservation {
            var value = chat(texts)
            value.snapshot.elements.removeAll { $0.id == "input" }
            var back = element("pixel-back", "视觉:返回", 0.09, 0.08, 0.04); back.source = "local_visual"
            var more = element("pixel-more", "视觉:更多", 0.91, 0.08, 0.06); more.source = "local_visual"
            var plus = element("pixel-plus", "视觉:添加", 0.92, 0.9, 0.06); plus.source = "local_visual"
            value.snapshot.elements += [back, more, plus]
            return value
        }
        let visualProfile = profile(), visualFirst = visualChat(["A", "B", "C", "D"]), visualNext = visualChat(["E", "F", "A", "B"])
        expect(PhonePageAdapters.identity(in: visualFirst.snapshot) == nil, "Empty composer fixture contains no invented OCR placeholder")
        expect(WeChatContactIdentity.chatPage(snapshot: visualFirst.snapshot, title: title)?.scene == "wechat.chat", "Three locally detected pixel symbols plus the exact title establish a supported chat structure")
        rejects({ _ = try ChatEvidenceFrame.from(snapshot: visualFirst.snapshot) }, "A contact title and pixel symbols alone still cannot establish the account")
        let visualFixture = ContactCaptureFixture([visualProfile, visualFirst, visualNext])
        var visualRequest = request; visualRequest.scopeID = "visual-contact"
        var visualAmbiguous = false
        do { _ = try await visualFixture.driver.read(request: visualRequest, store: store) } catch ChatEvidenceError.ambiguousContinuity { visualAmbiguous = true }
        let visualSession = try store.session(id: visualRequest.scopeID)
        expect(!visualAmbiguous && visualSession.messages.count == 4 && visualSession.pageSelection != nil && visualFixture.scrolls.isEmpty && visualFixture.taps == ["message"], "Empty-composer structure binds a fixed first-page sample, without a second-page observation")
        expect(visualSession.frames[0].conversation.evidenceElementIDs.contains("pixel-plus"), "Conversation evidence archives the actual local pixel control source")
        expect(try ChatEvidenceStore(url: storeURL).session(id: "visual-contact").frames[0].conversation.kind == .contactProfileNavigation, "Visual chat proof revalidates together with its independently observed profile after reload")
        for source in ["ocr", "model", "platform_identity"] {
            var forgedVisual = visualFirst.snapshot
            for index in forgedVisual.elements.indices where forgedVisual.elements[index].source == "local_visual" { forgedVisual.elements[index].source = source }
            expect(WeChatContactIdentity.chatPage(snapshot: forgedVisual, title: title) == nil, "Visual labels supplied as \(source) cannot replace actual local pixel evidence")
        }
        for missing in ["pixel-back", "pixel-more", "pixel-plus"] {
            var missingVisual = visualFirst.snapshot; missingVisual.elements.removeAll { $0.id == missing }
            expect(WeChatContactIdentity.chatPage(snapshot: missingVisual, title: title) == nil, "Missing \(missing) keeps the empty composer unsupported")
        }
        var misplaced = visualFirst.snapshot
        misplaced.elements[misplaced.elements.firstIndex { $0.id == "pixel-plus" }!].rect.x = 0.3
        expect(WeChatContactIdentity.chatPage(snapshot: misplaced, title: title) == nil, "A plus symbol outside the observed composer region cannot identify the chat")
        var staticProfile = profile(); staticProfile.confirmedAt = staticProfile.snapshot.capturedAt.addingTimeInterval(90)
        time = staticProfile.confirmedAt!
        let staticChat = chat(["current after static profile"])
        let idleFixture = ContactCaptureFixture([staticProfile, staticChat])
        let idleBootstrap = try await idleFixture.driver.bootstrap(target: target)
        expect(idleBootstrap.conversation.contactNavigation?.profile.snapshot.capturedAt == staticProfile.snapshot.capturedAt &&
            idleBootstrap.conversation.contactNavigation?.profile.confirmedAt == staticProfile.confirmedAt,
            "Fresh idle confirmation does not replace or reject the original static profile pixel timestamp")

        // Unlike the structural fixtures above, this section creates actual
        // RGBA pixels and invokes the production geometric detector. Its
        // detected controls then flow through the production contact driver.
        func glyphRaster(dark: Bool = false, omitting: Set<String> = []) -> PhoneRasterImage {
            let width = 320, height = 640, background: UInt8 = dark ? 5 : 250, ink: UInt8 = dark ? 245 : 10
            var bytes = [UInt8](repeating: background, count: width * height * 4)
            for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = 255 }
            func put(_ x: Int, _ y: Int) {
                guard x >= 0, x < width, y >= 0, y < height else { return }
                let offset = (y * width + x) * 4
                bytes[offset] = ink; bytes[offset + 1] = ink; bytes[offset + 2] = ink
            }
            if !omitting.contains("视觉:返回") {
                for y in 44...62 { let x = 14 + abs(y - 53); put(x, y); put(x + 1, y) }
            }
            if !omitting.contains("视觉:更多") {
                for center in [281, 288, 295] { for y in 50...52 { for x in (center - 1)...(center + 1) { put(x, y) } } }
            }
            if !omitting.contains("视觉:添加") {
                for y in 580...600 { for x in 279...299 {
                    let dx = Double(x - 289) / 10, dy = Double(y - 590) / 10, radius = hypot(dx, dy)
                    if abs(radius - 0.94) < 0.09 || (abs(dx) < 0.11 && abs(dy) < 0.61) || (abs(dy) < 0.11 && abs(dx) < 0.61) { put(x, y) }
                } }
            }
            return .init(width: width, height: height, rgba: bytes)
        }
        func detectedChat(_ texts: [String], dark: Bool = false, omitting: Set<String> = [], name: String? = nil) -> WeChatConversationObservation {
            var value = chat(texts, title: name)
            value.snapshot.elements.removeAll { $0.id == "input" }
            value.snapshot.elements += PhoneVisualControls.detect(in: glyphRaster(dark: dark, omitting: omitting))
            return value
        }
        for dark in [false, true] {
            let pixels = glyphRaster(dark: dark), actualControls = PhoneVisualControls.detect(in: pixels)
            expect(pixels.valid && actualControls.count == 3, "Actual \(dark ? "dark" : "light") RGBA raster produces the three production glyph detections")
            expect(actualControls.allSatisfy { $0.source == "local_visual" && $0.id.hasPrefix("visual.") }, "Contact evidence uses detector-generated controls rather than fixture-authored visual labels")
            let pixelProfile = profile(), pixelFirst = detectedChat(["A", "B", "C", "D"], dark: dark), pixelNext = detectedChat(["E", "F", "A", "B"], dark: dark)
            let pixelFixture = ContactCaptureFixture([pixelProfile, pixelFirst, pixelNext])
            var pixelRequest = request; pixelRequest.scopeID = "raster-contact-\(dark)"
            var pixelAmbiguous = false
            do { _ = try await pixelFixture.driver.read(request: pixelRequest, store: store) } catch ChatEvidenceError.ambiguousContinuity { pixelAmbiguous = true }
            let pixelSession = try store.session(id: pixelRequest.scopeID)
            expect(!pixelAmbiguous && pixelSession.messages.count == 4 && pixelSession.pageSelection != nil && pixelFixture.taps == ["message"] && pixelFixture.scrolls.isEmpty, "Production RGBA glyph detection proves profile/chat and immutable single-page range in \(dark ? "dark" : "light") mode")
            let selected = pixelSession.frames[0].conversation.evidenceElementIDs
            expect(selected.filter { $0.hasPrefix("visual.") }.count == 3, "Archived contact proof contains all three actual production detector IDs")
            expect(try ChatEvidenceStore(url: storeURL).session(id: pixelRequest.scopeID).pageSelection != nil, "The detector-derived accepted proof and fixed page selection restore in one transaction")
        }
        for missing in ["视觉:返回", "视觉:更多", "视觉:添加"] {
            let image = glyphRaster(omitting: [missing]), actual = PhoneVisualControls.detect(in: image)
            expect(!actual.contains { $0.label == missing }, "Removing the \(missing) glyph pixels actually removes that production detection")
            let missingFixture = ContactCaptureFixture([profile(), detectedChat(["A", "B"], omitting: [missing])])
            var failed = false
            do { _ = try await missingFixture.driver.bootstrap(target: target) } catch { failed = true }
            expect(failed && missingFixture.taps == ["message"] && missingFixture.scrolls.isEmpty, "Missing actual \(missing) pixels stop bootstrap after one navigation, with no chat read or scroll")
        }
        let pixelWrongPage = ContactCaptureFixture([profile(), detectedChat(["A", "B"], name: "另一个会话")])
        var pixelWrongPageRejected = false
        do { _ = try await pixelWrongPage.driver.bootstrap(target: target) } catch { pixelWrongPageRejected = true }
        expect(pixelWrongPageRejected && pixelWrongPage.taps == ["message"], "Three real detected glyphs do not authorize a different conversation page")
        let pixelWrongAccount = ContactCaptureFixture([profile(account: "wxid_wrong123"), detectedChat(["A", "B"])])
        var pixelWrongAccountRejected = false
        do { _ = try await pixelWrongAccount.driver.bootstrap(target: target) } catch { pixelWrongAccountRejected = true }
        expect(pixelWrongAccountRejected && pixelWrongAccount.taps.isEmpty, "Real detected chat glyphs cannot bypass a same-name wrong-account profile; no navigation input is sent")

        let duringProfile = profile()
        var duringChat = detectedChat(["pixels changed during click wait"])
        duringChat.snapshot.capturedAt = duringProfile.snapshot.capturedAt.addingTimeInterval(0.15)
        duringChat.confirmedAt = duringProfile.snapshot.capturedAt.addingTimeInterval(0.3)
        let duringFixture = ContactCaptureFixture([duringProfile, duringChat])
        let duringProof = try await duringFixture.driver.bootstrap(target: target)
        let duringNavigation = duringProof.conversation.contactNavigation!
        expect(duringNavigation.tapStartedAt < duringProof.snapshot.capturedAt && duringProof.snapshot.capturedAt < duringNavigation.tapCompletedAt,
            "Actual chat pixels produced during the tap's BLE wait are eligible when the system confirms them after input completion")
        expect(duringNavigation.chatConfirmedAt == duringChat.confirmedAt && duringProof.snapshot.capturedAt == duringChat.snapshot.capturedAt,
            "Navigation evidence keeps the real during-tap pixel time and separate post-tap system confirmation")
        var duringSession = ChatEvidenceSession(request: .init(scopeID: "during-tap-capture", conversation: target, range: .latest(count: 1), maxPages: 1))
        duringSession.frames = [duringProof]
        duringSession.messages = duringProof.rows.map { .init(id: UUID().uuidString, observation: $0, anchors: [$0.anchor]) }
        duringSession.state = .complete
        try store.save(duringSession)
        let reloadedDuring = try ChatEvidenceStore(url: storeURL).session(id: duringSession.id)
        expect(reloadedDuring.frames[0].conversation.contactNavigation?.chatConfirmedAt == duringChat.confirmedAt,
            "Post-tap system confirmation remains available for complete archived proof validation")
        let temporalProfile = profile()
        var stalePixels = detectedChat(["old image cannot inherit"])
        stalePixels.snapshot.capturedAt = temporalProfile.snapshot.capturedAt.addingTimeInterval(0.05)
        stalePixels.confirmedAt = temporalProfile.snapshot.capturedAt.addingTimeInterval(0.4)
        let stalePixelFixture = ContactCaptureFixture([temporalProfile, stalePixels])
        var stalePixelRejected = false
        do { _ = try await stalePixelFixture.driver.bootstrap(target: target) } catch { stalePixelRejected = true }
        expect(stalePixelRejected && stalePixelFixture.taps.count == 1, "Fresh idle confirmation cannot promote pixels that predate the actual tap start")
        let earlyProfile = profile()
        var earlyConfirmation = detectedChat(["confirmation predates input completion"])
        earlyConfirmation.snapshot.capturedAt = earlyProfile.snapshot.capturedAt.addingTimeInterval(0.15)
        earlyConfirmation.confirmedAt = earlyProfile.snapshot.capturedAt.addingTimeInterval(0.18)
        let earlyFixture = ContactCaptureFixture([earlyProfile, earlyConfirmation])
        var earlyRejected = false
        do { _ = try await earlyFixture.driver.bootstrap(target: target) } catch { earlyRejected = true }
        expect(earlyRejected, "Confirmation from before the tap completes cannot authorize the navigation result")
        var withoutConfirmation = duringProof
        withoutConfirmation.conversation.contactNavigation?.chatConfirmedAt = nil
        rejects({ try withoutConfirmation.validate(for: target) }, "Old or edited proof without confirmation conservatively rejects pixels captured before tap completion")
        var olderStrongProof = session.frames[0]
        olderStrongProof.conversation.contactNavigation?.chatConfirmedAt = nil
        try olderStrongProof.validate(for: target)
        expect(true, "Legacy proof lacking optional confirmation is accepted only when its pixels themselves postdate tap completion")
        struct FrameEnvelope: Codable { var frame: ChatEvidenceFrame }
        let navigationEncoder = JSONEncoder()
        var legacyObject = try JSONSerialization.jsonObject(with: navigationEncoder.encode(FrameEnvelope(frame: session.frames[0]))) as! [String: Any]
        var legacyFrame = legacyObject["frame"] as! [String: Any], legacyConversation = legacyFrame["conversation"] as! [String: Any]
        var legacyNavigation = legacyConversation["contactNavigation"] as! [String: Any]
        legacyNavigation.removeValue(forKey: "chatConfirmedAt"); legacyConversation["contactNavigation"] = legacyNavigation
        legacyFrame["conversation"] = legacyConversation; legacyObject["frame"] = legacyFrame
        let legacyDecoded = try JSONDecoder().decode(FrameEnvelope.self, from: JSONSerialization.data(withJSONObject: legacyObject)).frame
        try legacyDecoded.validate(for: target)
        expect(legacyDecoded.conversation.contactNavigation?.chatConfirmedAt == nil, "Optional confirmation decodes old JSON without manufacturing a system confirmation timestamp")
        let waitingProfile = profile()
        var unchangedWaitingProfile = waitingProfile
        unchangedWaitingProfile.frameID = UUID().uuidString
        unchangedWaitingProfile.confirmedAt = waitingProfile.snapshot.capturedAt.addingTimeInterval(0.3)
        var waitingChat = detectedChat(["opened after idle profile observation"])
        waitingChat.snapshot.capturedAt = waitingProfile.snapshot.capturedAt.addingTimeInterval(0.5)
        waitingChat.confirmedAt = waitingProfile.snapshot.capturedAt.addingTimeInterval(0.6)
        let waitingFixture = ContactCaptureFixture([waitingProfile, unchangedWaitingProfile, waitingChat])
        let waitingProof = try await waitingFixture.driver.bootstrap(target: target)
        expect(waitingFixture.taps.count == 1 && waitingFixture.reads == 3 && waitingProof.conversation.kind == .contactProfileNavigation,
            "A real fresh idle confirmation on unchanged profile pixels permits one further bounded read without replaying navigation")

        // Built-in helper profiles use the actual reserved account, never the
        // display-name alias alone. These OCR coordinates follow the separately
        // retained device profile screenshot; navigation stays synthetic here.
        let builtinTarget = ChatConversationTarget(stableID: "wechat.builtin.file-transfer", title: "文件传输助手", deviceKey: device)
        func builtinProfile(account: String = "filehelper", split: Bool = false, aboutVisible: Bool = true,
                            messageLabel: String = "Messages") -> WeChatConversationObservation {
            var elements = [element("builtin-name", builtinTarget.title, 0.358, 0.146, 0.287),
                element("builtin-status-dot", "•", 0.334, 0.034, 0.03),
                element("builtin-description-1", "Transfer text, images, audio and video files", 0.587, 0.273, 0.738),
                element("builtin-description-2", "between your device and your PC", 0.508, 0.293, 0.581),
                element("builtin-message", messageLabel, 0.502, 0.357, 0.247)]
            if aboutVisible { elements.append(element("builtin-about", "About", 0.09, 0.282, 0.11)) }
            if split {
                elements += [element("builtin-account-label", "Weixin ID:", 0.29, 0.178, 0.15),
                    element("builtin-account-value", account, 0.47, 0.178, 0.18)]
            } else { elements.append(element("builtin-account", "Weixin ID: " + account, 0.388, 0.178, 0.347)) }
            elements += PhoneVisualControls.detect(in: glyphRaster(dark: true, omitting: ["视觉:添加"]))
            return observation(elements)
        }
        func builtinChat(_ texts: [String], capture: UUID? = nil) -> WeChatConversationObservation {
            var value = chat(texts, title: builtinTarget.title, capture: capture)
            value.snapshot.elements.removeAll { $0.id == "input" }
            value.snapshot.elements += PhoneVisualControls.detect(in: glyphRaster(dark: true))
            return value
        }
        let builtinInitial = builtinProfile(), builtinIdentity = try WeChatContactIdentity.profile(snapshot: builtinInitial.snapshot,
            frameID: builtinInitial.frameID, captureSessionID: stream, target: builtinTarget)
        expect(builtinIdentity.account == "filehelper" && builtinIdentity.messageElementID == "builtin-message",
            "Reserved filehelper account plus actual profile structure identifies the built-in scope independently of its nickname")
        try builtinIdentity.validate(for: builtinTarget)
        expect(builtinIdentity.evidenceElementIDs.contains("builtin-account") &&
               builtinIdentity.evidenceElementIDs.contains("builtin-description-1") && builtinIdentity.evidenceElementIDs.contains("builtin-description-2"),
            "The built-in proof retains the exact account field and both original About text source lines")
        let builtinSplit = builtinProfile(split: true, messageLabel: "• Messages")
        let splitBuiltinIdentity = try WeChatContactIdentity.profile(snapshot: builtinSplit.snapshot, frameID: builtinSplit.frameID,
            captureSessionID: stream, target: builtinTarget)
        expect(splitBuiltinIdentity.evidenceElementIDs.contains("builtin-account-value"),
            "A real split Weixin ID field and the precisely observed bubble-icon Messages label preserve exact account evidence")
        let obscuredAbout = builtinProfile(aboutVisible: false)
        _ = try WeChatContactIdentity.profile(snapshot: obscuredAbout.snapshot, frameID: obscuredAbout.frameID,
            captureSessionID: stream, target: builtinTarget)
        expect(true, "An obscured section label does not substitute for or remove the mandatory full dedicated About text")
        var englishOrdinary = profile()
        englishOrdinary.snapshot.elements[englishOrdinary.snapshot.elements.firstIndex { $0.id == "account" }!].label = "Weixin ID: " + account
        let englishIdentity = try WeChatContactIdentity.profile(snapshot: englishOrdinary.snapshot, frameID: englishOrdinary.frameID,
            captureSessionID: stream, target: target)
        expect(englishIdentity.account == account, "English Weixin ID is an exact field-label alias; ordinary account identity and structural checks remain unchanged")

        var builtinRequest = ChatReadRequest(scopeID: "explicit-builtin-profile", conversation: builtinTarget, range: .currentPage(limit: 4), maxPages: 1)
        let builtinTape = ContactCaptureFixture([builtinInitial, builtinChat(["A", "小林负责，周五交付"]), builtinChat(["E", "F", "A", "小林负责，周五交付"])])
        var builtinAmbiguous = false
        do { _ = try await builtinTape.driver.read(request: builtinRequest, store: store) } catch ChatEvidenceError.ambiguousContinuity { builtinAmbiguous = true }
        let builtinSession = try store.session(id: builtinRequest.scopeID)
        expect(!builtinAmbiguous && builtinTape.taps == ["builtin-message"] && builtinTape.scrolls.isEmpty && builtinSession.messages.count == 2 && builtinSession.pageSelection != nil,
            "No-intro built-in profile binds the explicit current-page sample and never guesses latest or reads another page")
        expect(builtinSession.frames[0].conversation.kind == .contactProfileNavigation &&
               builtinSession.frames[0].conversation.contactNavigation?.profile.account == "filehelper" &&
               builtinSession.frames.count == 1,
            "The helper retains its auditable profile navigation without minting a new controlled-scroll identity")
        expect(builtinSession.frames.allSatisfy { $0.snapshot.elements.allSatisfy { $0.source != "platform_identity" } },
            "No fake platform_identity is injected into any helper chat frame")
        expect(try ChatEvidenceStore(url: storeURL).session(id: builtinRequest.scopeID) == builtinSession,
            "Built-in profile evidence, real source anchors and navigation timing survive strict store audit")
        let builtinSummary = try await ChatEvidenceSummarizer(model: { _ in
            let message = builtinSession.messages.first { $0.observation.text == "小林负责，周五交付" }!
            return "{\"claims\":[{\"category\":\"task\",\"statement\":\"小林周五交付\",\"citations\":[{\"messageID\":\"\(message.id)\",\"quote\":\"小林负责，周五交付\"}],\"owner\":\"小林\",\"deadline\":\"周五\"}]}"
        }).summarize(sessionID: builtinRequest.scopeID, store: store)
        expect(builtinSummary.messageIDs.count == 2 && builtinSummary.claims[0].owner == "小林",
            "Built-in profile → reader → store → injected model → strict source citation report completes without a real API")

        for accountValue in ["wxid_fixture123", "FileHelper", "tilenelper"] {
            let rejected = ContactCaptureFixture([builtinProfile(account: accountValue), builtinChat(["never read"])])
            var failed = false
            do { _ = try await rejected.driver.bootstrap(target: builtinTarget) } catch { failed = true }
            expect(failed && rejected.taps.isEmpty && rejected.reads == 1,
                "Same-name contact or OCR-misread account cannot become the reserved helper: " + accountValue)
        }
        for removed in ["builtin-name", "builtin-account", "builtin-description-1", "builtin-description-2", "builtin-message", "视觉:返回", "视觉:更多"] {
            var missing = builtinProfile()
            missing.snapshot.elements.removeAll { $0.id == removed || $0.label == removed }
            let rejected = ContactCaptureFixture([missing, builtinChat(["never read"])])
            var failed = false
            do { _ = try await rejected.driver.bootstrap(target: builtinTarget) } catch { failed = true }
            expect(failed && rejected.taps.isEmpty,
                "Missing independent builtin profile evidence stops before Messages: " + removed)
        }
        for id in ["builtin-account", "builtin-message"] {
            var duplicate = builtinProfile()
            var second = duplicate.snapshot.elements.first { $0.id == id }!
            second.id += "-duplicate"; duplicate.snapshot.elements.append(second)
            let rejected = ContactCaptureFixture([duplicate])
            var failed = false
            do { _ = try await rejected.driver.bootstrap(target: builtinTarget) } catch { failed = true }
            expect(failed && rejected.taps.isEmpty, "Duplicate reserved-account or Messages rows are ambiguous: " + id)
        }
        var copiedChat = builtinProfile()
        copiedChat.snapshot.elements += [element("top-chat-title", builtinTarget.title, 0.5, 0.08)] +
            PhoneVisualControls.detect(in: glyphRaster(dark: true)).filter { $0.label == "视觉:添加" }
        let copiedChatTape = ContactCaptureFixture([copiedChat])
        var copiedRejected = false
        do { _ = try await copiedChatTape.driver.bootstrap(target: builtinTarget) } catch { copiedRejected = true }
        expect(copiedRejected && copiedChatTape.taps.isEmpty,
            "Chat bubbles copying a nickname, reserved ID text and About text cannot masquerade as the profile layout")
        var modelAccount = builtinProfile()
        modelAccount.snapshot.elements[modelAccount.snapshot.elements.firstIndex { $0.id == "builtin-account" }!].source = "model"
        let modelAccountTape = ContactCaptureFixture([modelAccount])
        var modelAccountRejected = false
        do { _ = try await modelAccountTape.driver.bootstrap(target: builtinTarget) } catch { modelAccountRejected = true }
        expect(modelAccountRejected && modelAccountTape.taps.isEmpty, "Model text cannot establish the helper's reserved account")
        var genericDetails = builtinProfile()
        genericDetails.snapshot.elements.removeAll { $0.id.hasPrefix("builtin-description") || $0.id == "builtin-account" || $0.id == "builtin-message" }
        genericDetails.snapshot.elements += [element("details-heading", "Details", 0.5, 0.08), element("search-history", "Search Chat History", 0.4, 0.3),
            element("pin-chat", "Sticky on Top", 0.4, 0.4), element("clear-chat", "Clear Chat History", 0.4, 0.5)]
        let detailsTape = ContactCaptureFixture([genericDetails])
        var detailsRejected = false
        do { _ = try await detailsTape.driver.bootstrap(target: builtinTarget) } catch { detailsRejected = true }
        expect(detailsRejected && detailsTape.taps.isEmpty, "A generic Details page with the helper nickname and normal settings is not independent identity")
        var conflictingBuiltin = builtinProfile()
        conflictingBuiltin.snapshot.elements.append(element("different-account-field", "Weixin ID: wxid_someone123", 0.4, 0.218, 0.37))
        rejects({ _ = try WeChatContactIdentity.profile(snapshot: conflictingBuiltin.snapshot, frameID: conflictingBuiltin.frameID,
            captureSessionID: stream, target: builtinTarget) }, "A conflicting extra account field cannot be ignored in a built-in profile")
        var ordinaryAlias = builtinTarget; ordinaryAlias.stableID = try WeChatContactIdentity.stableID(account: "filehelper")
        rejects({ _ = try WeChatContactIdentity.profile(snapshot: builtinInitial.snapshot, frameID: builtinInitial.frameID,
            captureSessionID: stream, target: ordinaryAlias) }, "The reserved helper proof cannot be relabeled as an ordinary-contact stable ID")
        var copiedNameOnly = profile(title: builtinTarget.title)
        copiedNameOnly.snapshot.elements += builtinInitial.snapshot.elements.filter { $0.id.hasPrefix("builtin-description") }
        let copiedNameTape = ContactCaptureFixture([copiedNameOnly])
        var copiedNameRejected = false
        do { _ = try await copiedNameTape.driver.bootstrap(target: builtinTarget) } catch { copiedNameRejected = true }
        expect(copiedNameRejected && copiedNameTape.taps.isEmpty, "An ordinary same-name contact copying the entire About description still has the wrong account")
        for fault in ["stream", "device", "title", "old-pixels", "early-confirmation", "cancel"] {
            let start = builtinProfile()
            var finish = builtinChat(["never accepted"])
            if fault == "stream" { finish.captureSessionID = UUID() }
            if fault == "device" { finish.snapshot.deviceKey = "different-device" }
            if fault == "title" { finish.snapshot.elements[finish.snapshot.elements.firstIndex { $0.id == "title" }!].label = "同名联系人" }
            if fault == "old-pixels" { finish.snapshot.capturedAt = start.snapshot.capturedAt; finish.confirmedAt = start.snapshot.capturedAt.addingTimeInterval(1) }
            if fault == "early-confirmation" { finish.snapshot.capturedAt = start.snapshot.capturedAt.addingTimeInterval(0.15); finish.confirmedAt = start.snapshot.capturedAt.addingTimeInterval(0.18) }
            let rejected = ContactCaptureFixture([start, finish]); rejected.cancelTap = fault == "cancel"
            var failed = false
            do { _ = try await rejected.driver.bootstrap(target: builtinTarget) } catch { failed = true }
            expect(failed && rejected.taps == ["builtin-message"], "Built-in navigation reuses every original identity, timing and cancellation guard: " + fault)
        }
        let builtinResume = ContactCaptureFixture([builtinChat(["E", "F", "A", "小林负责，周五交付"])])
        var builtinResumeFailed = false
        do { _ = try await builtinResume.driver.read(request: builtinRequest, store: store) } catch { builtinResumeFailed = true }
        let retainedBuiltinCount = try store.session(id: builtinRequest.scopeID).messages.count
        expect(builtinResumeFailed && builtinResume.taps.isEmpty && builtinResume.scrolls.isEmpty &&
               retainedBuiltinCount == 2,
            "A saved helper profile cannot authorize a later title-only read; failure preserves the prior accepted batch")
        let builtinDiskAdapter = ChatEvidenceCaptureAdapter()
        rejects({ _ = try builtinDiskAdapter.begin(bootstrap: builtinSession.frames[0], target: builtinTarget) },
            "Archived built-in profile navigation does not restore live bootstrap permission")
        let liveBuiltin = try await ContactCaptureFixture([builtinProfile(), builtinChat(["one current message"])]).driver.bootstrap(target: builtinTarget)
        let builtinOnce = ChatEvidenceCaptureAdapter()
        _ = try builtinOnce.begin(bootstrap: liveBuiltin, target: builtinTarget)
        rejects({ _ = try ChatEvidenceCaptureAdapter().begin(bootstrap: liveBuiltin, target: builtinTarget) },
            "An actual built-in profile bootstrap is consumed only once across capture adapters")
        var directIntro = chat(["ordinary intro path remains"], title: builtinTarget.title)
        directIntro.snapshot.elements.append(element("builtin-intro", "你可以在手机和电脑间互传文件", 0.5, 0.22, 0.64))
        let directIntroTape = ContactCaptureFixture([directIntro])
        let directIntroProof = try await directIntroTape.driver.bootstrap(target: builtinTarget)
        expect(directIntroProof.conversation.kind == .builtInTransfer && directIntroTape.taps.isEmpty,
            "The existing independently proved intro-chat path remains input-free")
        builtinRequest.scopeID = "builtin-one-page-exact-ten"; builtinRequest.range = .currentPage(limit: 10); builtinRequest.maxPages = 1
        let tenProfile = builtinProfile()
        var tenChat = builtinChat((1...10).map { "explicit fixture message \($0)" })
        for index in 0..<10 {
            let row = tenChat.snapshot.elements.firstIndex { $0.id == "bubble-\(index)" }!
            tenChat.snapshot.elements[row].rect.y = 0.27 + Double(index) * 0.055
        }
        let tenTape = ContactCaptureFixture([tenProfile, tenChat])
        let tenSession = try await tenTape.driver.read(request: builtinRequest, store: store)
        expect(tenSession.selectedMessages.count == 10 && tenSession.state == .complete && tenTape.scrolls.isEmpty,
            "An explicitly scoped current-page sample completes with ten actual fixture rows and no extra scroll")

        // These dimensions match the production 320×694 raster observed from
        // the actual 590×1280 profile image: 6×12 back and 12×2 ellipsis.
        func quantizedGlyphRaster(omitting: Set<String> = []) -> PhoneRasterImage {
            let width = 320, height = 694
            var bytes = [UInt8](repeating: 15, count: width * height * 4)
            for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = 255 }
            func put(_ x: Int, _ y: Int) {
                let offset = (y * width + x) * 4
                bytes[offset] = 220; bytes[offset + 1] = 220; bytes[offset + 2] = 220
            }
            if !omitting.contains("视觉:返回") {
                for y in 51...62 { put(13 + Int(abs(Double(y) - 56.5)), y) }
            }
            if !omitting.contains("视觉:更多") {
                for left in [293, 298, 303] { for y in 56...57 { for x in left...(left + 1) { put(x, y) } } }
            }
            if !omitting.contains("视觉:添加") {
                for y in 580...600 { for x in 279...299 {
                    let dx = Double(x - 289) / 10, dy = Double(y - 590) / 10, radius = hypot(dx, dy)
                    if abs(radius - 0.94) < 0.09 || (abs(dx) < 0.11 && abs(dy) < 0.61) || (abs(dy) < 0.11 && abs(dx) < 0.61) { put(x, y) }
                } }
            }
            return .init(width: width, height: height, rgba: bytes)
        }
        let quantizedControls = PhoneVisualControls.detect(in: quantizedGlyphRaster())
        expect(quantizedControls.count == 3 && quantizedControls.first { $0.label == "视觉:返回" }?.rect.width == 6.0/320.0 &&
               quantizedControls.first { $0.label == "视觉:更多" }?.rect.height == 2.0/694.0,
            "Actual 320×694 drawn pixels reach production detection with the observed six-pixel back and two-pixel ellipsis")
        var quantizedProfile = builtinProfile(), quantizedChat = builtinChat(["A", "B"])
        quantizedProfile.snapshot.elements.removeAll { $0.source == "local_visual" }
        quantizedProfile.snapshot.elements += quantizedControls.filter { $0.label != "视觉:添加" }
        quantizedChat.snapshot.elements.removeAll { $0.source == "local_visual" }
        quantizedChat.snapshot.elements += quantizedControls
        var quantizedRequest = builtinRequest; quantizedRequest.scopeID = "builtin-real-pixel-quantization"; quantizedRequest.range = .currentPage(limit: 2)
        let quantizedTape = ContactCaptureFixture([quantizedProfile, quantizedChat])
        let quantizedSession = try await quantizedTape.driver.read(request: quantizedRequest, store: store)
        expect(quantizedSession.state == .complete && quantizedSession.messages.count == 2 && quantizedTape.taps == ["builtin-message"],
            "Production quantized glyphs pass the full reserved profile → Messages → current chat → reader and store proof chain")
        var fakeQuantizedChat = quantizedChat.snapshot
        for index in fakeQuantizedChat.elements.indices where fakeQuantizedChat.elements[index].source == "local_visual" {
            fakeQuantizedChat.elements[index].source = "ocr"
        }
        expect(WeChatContactIdentity.chatPage(snapshot: fakeQuantizedChat, title: builtinTarget.title) == nil,
            "OCR text with identical quantized glyph labels cannot enter the local-pixel tolerance path")
        for missing in ["视觉:返回", "视觉:更多"] {
            let controls = PhoneVisualControls.detect(in: quantizedGlyphRaster(omitting: [missing]))
            var rejected = quantizedChat.snapshot
            rejected.elements.removeAll { $0.source == "local_visual" }; rejected.elements += controls
            expect(WeChatContactIdentity.chatPage(snapshot: rejected, title: builtinTarget.title) == nil,
                "Quantization tolerance does not replace a missing real detected glyph: " + missing)
        }

        checks += try await CurrentPageRangeChecks.run(folder: directory)
        checks += try await SystemIntroChecks.run(folder: directory)
        print("Contacts: \(checks) checks passed (production profile recognition → one real-control tap → immutable current-page evidence → strict summary; offline fixtures only)")
    }
}
