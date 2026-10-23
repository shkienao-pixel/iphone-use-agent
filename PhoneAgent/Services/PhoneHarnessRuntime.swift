import Foundation
#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif
import Vision

/// Native OCR and verified layout memory execute small UI workflows without a
/// remote model round trip for every tap or keystroke.
@MainActor
final class PhoneHarnessRuntime: PhoneHarnessDriving {
    private let executor: MouseExecutor
    private var memory: PhoneLayoutMemory
    private let memoryURL: URL
    private var cachedFrame: (UUID?, Date)?
    private var cachedSnapshot: PhoneUISnapshot?
    private var pendingLearning: (String, PhoneUIElement, PhoneUISnapshot, Date)?
    private var focusSelection: UUID?
    private var focusEstablishedAt = Date.distantPast
    private var lastFallback = ""
    private var lastInputCompletedAt: Date?
    private var lastObservedFrame: ScreenFrame?
    private let recognize: ((ScreenFrame) async throws -> [PhoneUIElement])?

    init(executor: MouseExecutor, memoryURL: URL? = nil,
         recognize: ((ScreenFrame) async throws -> [PhoneUIElement])? = nil) {
        self.executor = executor
        self.recognize = recognize
        self.memoryURL = memoryURL ?? URL.documentsDirectory.appendingPathComponent("phone-layout-memory.json")
        memory = (try? Data(contentsOf: self.memoryURL)).flatMap { try? JSONDecoder().decode(PhoneLayoutMemory.self, from: $0) } ?? PhoneLayoutMemory()
    }

    func reset() {
        pendingLearning = nil; focusSelection = nil; focusEstablishedAt = .distantPast
        cachedFrame = nil; cachedSnapshot = nil; lastFallback = ""
        lastInputCompletedAt = nil; lastObservedFrame = nil
    }

    func context(for frame: ScreenFrame) async throws -> String {
        let snapshot = try await observe(frame)
        let items = snapshot.elements.prefix(48).map { ["id": $0.id, "label": String($0.label.prefix(90)), "source": $0.source] }
        let object: [String: Any] = ["scene": snapshot.scene, "device": snapshot.deviceKey,
            "blocked": snapshot.blockingOverlay, "elements": items,
            "remembered_search": memory.control(named: "home.search", in: snapshot) != nil,
            "remembered_back": memory.control(named: "navigation.back", in: snapshot) != nil,
            "keyboard_ready": executor.ble.keyboardReady,
            "keyboard_focus_confirmed": executor.ble.keyboardReady && (keyboardVisible(snapshot) || trustedSearchFocus(frame, snapshot: snapshot)),
            "last_fallback": lastFallback]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func didExecute(_ action: AgentAction, frame: ScreenFrame) async {
        guard action.kind == .tap, let x = action.x, let y = action.y,
              let snapshot = try? await observe(frame), !snapshot.blockingOverlay else { return }
        let name: String
        if snapshot.scene == "home", let search = searchElement(snapshot), contains(search.rect, x: x, y: y) {
            pendingLearning = ("home.search", search, snapshot, Date()); return
        } else if snapshot.scene.hasPrefix("settings."), x < 0.25, (0.035...0.15).contains(y) {
            name = "navigation.back"
        } else { return }
        // The point only becomes remembered after a later local observation
        // proves the expected page transition. Dispatch is not success.
        let element = PhoneUIElement(id: "verified.back", label: "返回", rect: PhoneUIRect(
            x: max(0, x - 0.015), y: max(0, y - 0.012), width: 0.03, height: 0.024), source: "learned")
        var source = snapshot; source.elements.append(element)
        pendingLearning = (name, element, source, Date())
    }

    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        lastInputCompletedAt = nil; lastObservedFrame = nil
        let summary = try await executeSummary(request, frame: frame, mappedHome: mappedHome, nextFrame: nextFrame)
        let verified = lastObservedFrame.flatMap { observed in
            lastInputCompletedAt.map { observed.confirmedAt > $0 } == true ? observed : nil
        }
        return PhoneHarnessReceipt(summary: summary, verifiedFrame: verified, lastInputCompletedAt: lastInputCompletedAt)
    }

    private func executeSummary(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                                nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> String {
        try request.validate(); try Task.checkCancellation()
        lastFallback = ""
        let snapshot = try await observe(frame)
        guard !snapshot.blockingOverlay else { throw fallback("当前有遮挡或系统确认窗口，改用当前画面处理") }
        _ = try executor.validateCalibration(frame: frame)
        switch request.operation {
        case .open_search:
            if snapshot.scene == "search" { return "本地确认搜索页面已打开；尚未输入或提交" }
            _ = try await openSearch(frame, snapshot: snapshot, nextFrame: nextFrame)
            return "已由本地布局打开搜索，并确认进入搜索页面"
        case .open_app:
            return try await openApp(request.target!, frame: frame, snapshot: snapshot, mappedHome: mappedHome, nextFrame: nextFrame)
        case .tap:
            guard let element = snapshot.element(id: request.target!) ?? snapshot.matchingLabel(request.target!) else {
                throw fallback("目标元素不存在或标签不唯一，请使用本轮元素 ID 或重新观察")
            }
            try await tap(element, frame: frame)
            let fresh = try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame)
            let after = try await observe(fresh)
            try requireUnobstructed(after)
            return "已点击当前元素 \(element.id)；当前本地页面为 \(after.scene)，需按实际画面核对业务结果"
        case .back:
            let element: PhoneUIElement
            if let visible = backElement(snapshot) { element = visible }
            else if let saved = memory.control(named: "navigation.back", in: snapshot) {
                element = PhoneUIElement(id: "navigation.back", label: saved.label, rect: saved.rect, source: "learned")
            }
            else { throw fallback("此页的返回入口尚未学习，先由模型定位一次，成功返回后会自动记住") }
            try await tap(element, frame: frame)
            guard let (_, after) = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame, matching: {
                $0.scene != snapshot.scene && ($0.scene == "settings" || $0.scene.hasPrefix("settings."))
            }) else {
                forget("navigation.back", snapshot: snapshot)
                throw fallback("返回后的页面尚未确认，已停用本页返回记忆；从新画面继续")
            }
            remember("navigation.back", element: element, source: snapshot, destination: after)
            return "本地返回已核实：\(snapshot.scene) → \(after.scene)"
        case .home:
            guard mappedHome else { throw fallback("当前配件未确认主屏幕中键映射，请用可见辅助触控菜单返回") }
            try await primitive(.press_key, text: "home", frame: frame, mappedHome: true)
            guard try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame,
                matching: { $0.scene == "home" }) != nil else {
                throw fallback("已发送主屏幕按键，但尚未确认桌面，请检查当前画面")
            }
            return "已通过已确认的主屏幕映射返回桌面"
        case .type_text:
            guard executor.ble.keyboardReady, keyboardVisible(snapshot) || trustedSearchFocus(frame, snapshot: snapshot) else {
                throw fallback("没有本地确认的输入焦点；先点击输入框，或使用普通单步输入")
            }
            // A generic field may submit on Enter/Tab. Keep semantic typing to
            // a single field; explicit press_key handles authorized submission.
            guard !request.text!.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
                throw fallback("整段输入只填写一个字段；回车或 Tab 请明确调用 press_key")
            }
            try await primitive(.type, text: request.text!, frame: frame)
            let after = try await observe(try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame))
            try requireUnobstructed(after)
            return "已通过蓝牙键盘输入 \(request.text!.count) 个 ASCII 字符；请核对实际字段内容"
        case .press_key:
            guard executor.ble.keyboardReady, keyboardVisible(snapshot) || trustedSearchFocus(frame, snapshot: snapshot) else {
                throw fallback("没有本地确认的键盘焦点，未发送按键")
            }
            try await primitive(.press_key, text: request.target!, frame: frame)
            let after = try await observe(try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame))
            try requireUnobstructed(after)
            return "已发送按键 \(request.target!)；请根据新画面确认效果"
        }
    }

    private func openSearch(_ frame: ScreenFrame, snapshot: PhoneUISnapshot,
                            nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> (ScreenFrame, PhoneUISnapshot) {
        guard snapshot.scene == "home" else { throw fallback("open_search 只在已识别的主屏幕使用；当前页 \(snapshot.scene)") }
        let element: PhoneUIElement
        if let visible = searchElement(snapshot) { element = visible }
        else if let saved = memory.control(named: "home.search", in: snapshot) {
            element = PhoneUIElement(id: "home.search", label: saved.label, rect: saved.rect, source: "learned")
        }
        else { throw fallback("主屏幕搜索入口尚未识别，请先定位一次") }
        try await tap(element, frame: frame)
        guard let (fresh, after) = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: frame,
            nextFrame: nextFrame, matching: { $0.scene == "search" }) else {
            forget("home.search", snapshot: snapshot)
            throw fallback("搜索入口点击后未确认搜索页面，已停止连续操作")
        }
        remember("home.search", element: element, source: snapshot, destination: after)
        focusSelection = fresh.captureID; focusEstablishedAt = Date()
        return (fresh, after)
    }

    private func openApp(_ name: String, frame: ScreenFrame, snapshot: PhoneUISnapshot, mappedHome: Bool,
                         nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> String {
        guard executor.ble.keyboardReady,
              name.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw fallback("本地应用搜索需要 ASCII 应用名和可用硬件键盘；中文名称请按当前候选词界面处理")
        }
        var current = frame; var view = snapshot
        if view.scene != "home", view.scene != "search" {
            guard mappedHome else { throw fallback("请先返回桌面；当前没有可用的主屏幕映射") }
            try await primitive(.press_key, text: "home", frame: current, mappedHome: true)
            guard let home = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current,
                nextFrame: nextFrame, matching: { $0.scene == "home" }) else {
                throw fallback("已发送主屏幕按键，尚未确认桌面；没有继续搜索或输入")
            }
            (current, view) = home
        }
        if view.scene == "home" { (current, view) = try await openSearch(current, snapshot: view, nextFrame: nextFrame) }
        guard trustedSearchFocus(current, snapshot: view) else {
            throw fallback("搜索输入框焦点未由本地流程确认，请先调用 open_search 或点击搜索输入框")
        }
        try await primitive(.press_key, text: "select_all", frame: current)
        try await primitive(.type, text: name, frame: current)
        // Only an installed-app section is accepted. A matching web/contact/
        // suggestion label alone cannot establish that this is an app result.
        guard let result = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current,
            nextFrame: nextFrame, matching: { $0.scene == "search" && self.applicationResult(name, in: $0) != nil }) else {
            throw fallback("应用名已输入，但本地尚未找到唯一的应用结果；请根据当前搜索结果选择，勿重复输入")
        }
        (current, view) = result
        guard let app = applicationResult(name, in: view) else { throw fallback("应用结果已改变，请重新观察") }
        try await tap(app, frame: current)
        guard let destination = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current,
            nextFrame: nextFrame, matching: { self.matchesRequestedApp(name, snapshot: $0) }) else {
            throw fallback("已点击应用结果，但本地尚未确认目标应用身份；请根据当前画面核对，勿重复搜索或点击")
        }
        (current, view) = destination
        return "本地已完成搜索、输入和点击应用结果 \(name)，当前页面 \(view.scene)；请核对截图确认目标应用和任务结果"
    }

    /// Wait only for observations, never retry the input that caused a transition.
    /// The frame cap also bounds injected or unexpectedly high-rate streams.
    private func waitForSnapshot(after inputCompletedAt: Date, relativeTo source: ScreenFrame,
                                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame,
                                 matching: (PhoneUISnapshot) -> Bool) async throws -> (ScreenFrame, PhoneUISnapshot)? {
        let deadline = Date().addingTimeInterval(2)
        var newerThan = inputCompletedAt
        for _ in 0..<12 {
            try Task.checkCancellation()
            guard Date() < deadline else { return nil }
            let fresh: ScreenFrame
            do {
                fresh = try await withThrowingTaskGroup(of: ScreenFrame.self) { group in
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    let requiredAfter = newerThan
                    group.addTask { @MainActor in
                        try await self.checkedNextFrame(after: requiredAfter, relativeTo: source, nextFrame: nextFrame)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        throw TransitionWaitExpired()
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch is TransitionWaitExpired { return nil }
            let snapshot = try await observe(fresh)
            try requireUnobstructed(snapshot)
            guard Date() <= deadline else { return nil }
            if matching(snapshot) { return (fresh, snapshot) }
            newerThan = fresh.confirmedAt
        }
        return nil
    }

    private struct TransitionWaitExpired: Error {}

    private func checkedNextFrame(after: Date, relativeTo source: ScreenFrame,
                                  nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> ScreenFrame {
        try Task.checkCancellation()
        let fresh = try await nextFrame(after)
        try Task.checkCancellation()
        guard fresh.captureID == source.captureID, fresh.sourceWidth == source.sourceWidth,
              fresh.sourceHeight == source.sourceHeight, fresh.width == source.width, fresh.height == source.height,
              fresh.fullDisplay else {
            throw AgentError.message("手机工具等待期间共享或屏幕尺寸已改变，已停止")
        }
        guard fresh.confirmedAt > after else { throw fallback("没有收到动作完成后的新画面，已停止本地连续操作") }
        return fresh
    }

    private func matchesRequestedApp(_ name: String, snapshot: PhoneUISnapshot) -> Bool {
        // Other apps remain a model-verified fallback until their identity can
        // be recognized locally. Merely leaving Spotlight is not app identity.
        Self.normalized(name) == "settings" && (snapshot.scene == "settings" || snapshot.scene.hasPrefix("settings."))
    }

    private func primitive(_ kind: AgentAction.Kind, text: String, frame: ScreenFrame, mappedHome: Bool = false) async throws {
        try Task.checkCancellation(); _ = try executor.validateCalibration(frame: frame)
        try await executor.execute(AgentAction(kind: kind, text: text, reason: "本地手机工具"), frame: frame, mappedHomeAvailable: mappedHome)
        lastInputCompletedAt = Date()
        try Task.checkCancellation()
    }
    private func tap(_ element: PhoneUIElement, frame: ScreenFrame) async throws {
        guard element.rect.valid else { throw fallback("本地控件坐标无效") }
        try Task.checkCancellation(); _ = try executor.validateCalibration(frame: frame)
        try await executor.execute(AgentAction(kind: .tap, x: element.rect.centerX, y: element.rect.centerY, reason: "本地定位 \(element.id)"), frame: frame)
        lastInputCompletedAt = Date()
        try Task.checkCancellation()
    }

    private func observe(_ frame: ScreenFrame) async throws -> PhoneUISnapshot {
        try Task.checkCancellation()
        lastObservedFrame = frame
        if cachedFrame?.0 == frame.captureID, cachedFrame?.1 == frame.capturedAt, let cachedSnapshot { return cachedSnapshot }
        guard frame.fullDisplay, let image = frame.image.cgImage else { throw fallback("本地布局识别需要有效整屏画面") }
        let elements: [PhoneUIElement]
        if let recognize { elements = try await recognize(frame) }
        else { elements = try await Task.detached(priority: .userInitiated) { () -> [PhoneUIElement] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).sorted { a, b in
                let rowA = Int((a.boundingBox.midY * 80).rounded()), rowB = Int((b.boundingBox.midY * 80).rounded())
                return rowA == rowB ? a.boundingBox.minX < b.boundingBox.minX : rowA > rowB
            }.prefix(100).compactMap { result in
                guard let text = result.topCandidates(1).first, text.confidence >= 0.45 else { return nil }
                let b = result.boundingBox
                let rect = PhoneUIRect(x: max(0, b.minX), y: max(0, 1 - b.maxY), width: min(b.width, 1 - b.minX), height: min(b.height, b.maxY))
                guard rect.valid else { return nil }
                let identifier = "ocr.\(Self.labelKey(text.string)).\(Int((rect.centerX * 40).rounded())).\(Int((rect.centerY * 80).rounded()))"
                return PhoneUIElement(id: identifier, label: text.string, rect: rect, source: "ocr")
            }
        }.value }
        try Task.checkCancellation()
        let blockedLabels = ["allow", "don’t allow", "don't allow", "允许", "不允许", "确认付款", "face id", "enter passcode", "输入密码"]
        let blocked = elements.contains { blockedLabels.contains(Self.normalized($0.label)) } ||
            elements.contains { $0.label.contains("Phone Agent ·") }
        #if canImport(UIKit)
        let scale = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.traitCollection.displayScale ?? 0
        let display = "\(scale)|\(UIApplication.shared.preferredContentSizeCategory.rawValue)|\(UIAccessibility.isBoldTextEnabled)"
        #else
        let display = "offline"
        #endif
        let key = "\(frame.sourceWidth)x\(frame.sourceHeight)|\(display)|\(Locale.current.identifier)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        var snapshot = PhoneUISnapshot(deviceKey: key, scene: "unknown", elements: elements, capturedAt: frame.capturedAt, blockingOverlay: blocked)
        snapshot.scene = classify(snapshot)
        if let learning = pendingLearning {
            pendingLearning = nil
            if (0...8).contains(Date().timeIntervalSince(learning.3)) {
                remember(learning.0, element: learning.1, source: learning.2, destination: snapshot)
            }
        }
        if snapshot.scene != "search" { focusSelection = nil; focusEstablishedAt = .distantPast }
        if backElement(snapshot) == nil, let remembered = memory.control(named: "navigation.back", in: snapshot) {
            snapshot.elements.append(PhoneUIElement(id: "navigation.back", label: remembered.label, rect: remembered.rect, source: "learned"))
        }
        cachedFrame = (frame.captureID, frame.capturedAt); cachedSnapshot = snapshot
        return snapshot
    }

    private func classify(_ snapshot: PhoneUISnapshot) -> String {
        let lower = snapshot.elements.map { (Self.normalized($0.label), $0.rect) }
        let hasKeyboard = keyboardVisible(snapshot)
        // Settings has its own bottom Search field. Its large leading title
        // must be recognized before the Home search capsule heuristic.
        if lower.contains(where: { ["settings", "设置"].contains($0.0) && $0.1.centerY < 0.21 }),
           lower.contains(where: { ["wi-fi", "无线局域网", "wlan"].contains($0.0) }),
           lower.contains(where: { ["bluetooth", "蓝牙"].contains($0.0) }) { return "settings" }
        let searchWords = ["search", "搜索"]
        let hasCancel = lower.contains { ["cancel", "取消"].contains($0.0) }
        let spotlightSection = lower.contains { ["siri suggestions", "siri 建议", "apps", "应用", "top hit", "热门结果"].contains($0.0) }
        if (hasKeyboard || (hasCancel && spotlightSection)) &&
            lower.contains(where: { searchWords.contains($0.0) || ["cancel", "取消"].contains($0.0) }) { return "search" }
        let headings = lower.filter { $0.1.centerY < 0.15 && $0.1.centerX > 0.27 && $0.1.centerX < 0.77 }
        let known: [String: String] = ["accessibility":"accessibility", "辅助功能":"accessibility", "touch":"touch", "触控":"touch",
            "assistivetouch":"assistivetouch", "辅助触控":"assistivetouch", "devices":"devices", "设备":"devices"]
        for (title, _) in headings { if let id = known[title] { return "settings." + id } }
        let gridColumns = Set(lower.filter({ (0.12...0.78).contains($0.1.centerY) }).map { Int(($0.1.centerX * 4).rounded()) })
        if !hasKeyboard, searchElement(snapshot) != nil, gridColumns.count >= 3 { return "home" }
        return "unknown"
    }
    private func keyboardVisible(_ snapshot: PhoneUISnapshot) -> Bool {
        let labels = snapshot.elements.filter { $0.rect.centerY > 0.56 }.map { Self.normalized($0.label) }
        return labels.contains(where: { ["space", "空格"].contains($0) }) &&
            labels.contains(where: { ["return", "search", "go", "done", "换行", "搜索", "完成", "123"].contains($0) })
    }
    private func trustedSearchFocus(_ frame: ScreenFrame, snapshot: PhoneUISnapshot) -> Bool {
        snapshot.scene == "search" && focusSelection == frame.captureID && Date().timeIntervalSince(focusEstablishedAt) < 20
    }
    private func searchElement(_ snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        // Native OCR sometimes includes the capsule's magnifier as Q/O. Only
        // those exact observed forms and the centered Home region are aliases.
        let labels = ["search", "q search", "o search", "🔍 search", "搜索", "q 搜索", "o 搜索"]
        let matches = snapshot.elements.filter { $0.source == "ocr" && labels.contains(Self.normalized($0.label)) &&
            (0.35...0.65).contains($0.rect.centerX) && (0.70...0.90).contains($0.rect.centerY) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func backElement(_ snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard snapshot.scene.hasPrefix("settings.") else { return nil }
        let matches = snapshot.elements.filter { $0.source == "ocr" && $0.rect.centerX < 0.27 && (0.035...0.15).contains($0.rect.centerY) &&
            ["back", "返回", "settings", "设置", "accessibility", "辅助功能", "touch", "触控", "assistivetouch", "辅助触控"].contains(Self.normalized($0.label)) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func applicationResult(_ name: String, in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let sections = snapshot.elements.filter { ["apps", "应用", "应用程序"].contains(Self.normalized($0.label)) }
        guard let section = sections.first else { return nil }
        let nextSection = snapshot.elements.filter { $0.rect.centerY > section.rect.centerY &&
            ["contacts", "联系人", "messages", "信息", "websites", "网站", "search web", "搜索网页", "app store"].contains(Self.normalized($0.label)) }.map(\.rect.y).min() ?? 0.59
        let matches = snapshot.elements.filter { Self.normalized($0.label) == Self.normalized(name) &&
            $0.rect.centerY > section.rect.centerY && $0.rect.centerY < min(nextSection, 0.62) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func remember(_ name: String, element: PhoneUIElement, source: PhoneUISnapshot, destination: PhoneUISnapshot) {
        var source = source
        if source.element(id: element.id) == nil { source.elements.append(element) }
        guard (try? memory.record(name: name, element: element, source: source, destination: destination)) != nil else { return }
        persist()
    }
    private func forget(_ name: String, snapshot: PhoneUISnapshot) {
        memory.controls.removeAll { $0.deviceKey == snapshot.deviceKey && $0.scene == snapshot.scene && $0.name == name }
        cachedFrame = nil; cachedSnapshot = nil; persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: memoryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = memoryURL; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
    }
    private func fallback(_ message: String) -> PhoneHarnessFallback {
        lastFallback = String(message.prefix(240)); return PhoneHarnessFallback(message: lastFallback)
    }
    private func requireUnobstructed(_ snapshot: PhoneUISnapshot) throws {
        guard !snapshot.blockingOverlay else { throw fallback("页面出现遮挡或系统确认窗口，本地连续操作已停止") }
    }
    private func contains(_ rect: PhoneUIRect, x: Double, y: Double) -> Bool {
        (rect.x - 0.035...rect.x + rect.width + 0.035).contains(x) && (rect.y - 0.025...rect.y + rect.height + 0.025).contains(y)
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    nonisolated private static func labelKey(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
