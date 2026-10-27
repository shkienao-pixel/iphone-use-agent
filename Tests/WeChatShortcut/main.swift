import Foundation

@main struct WeChatShortcutChecks {
    @MainActor static func main() async throws {
        let capture = UUID()
        func e(_ id: String, _ label: String, _ x: Double, _ y: Double, _ width: Double = 0.18) -> PhoneUIElement {
            .init(id: id, label: label, rect: .init(x: x - width / 2, y: y - 0.015, width: width, height: 0.03), source: "ocr")
        }
        func frame(_ scene: String, _ elements: [PhoneUIElement], capturedAt: Date = Date()) -> WeChatShortcutFrame {
            .init(snapshot: .init(deviceKey: "fixture-device", scene: scene, elements: elements, capturedAt: capturedAt),
                  captureID: capture, frameID: UUID().uuidString, confirmedAt: capturedAt)
        }
        let row = e("row", "文件传输助手", 0.5, 0.3)
        let list = frame("wechat.list", [row])
        func transferChat() -> WeChatShortcutFrame {
            frame("wechat.chat", [e("back", "微信", 0.1, 0.08), e("title", "文件传输助手", 0.5, 0.08),
                e("proof", "可以在手机和电脑间互传文件", 0.5, 0.25, 0.64), e("input", "发送消息", 0.4, 0.9)])
        }
        var tapped: [String] = []
        let result = try await WeChatShortcutNavigation.run(initial: list, name: "文件传输助手", stableID: "wechat.builtin.file-transfer",
            tap: { tapped.append($0.id) }, read: { transferChat() })
        precondition(tapped == ["row"] && WeChatShortcutNavigation.transferChat(result.snapshot), "single row then verified chat")
        tapped = []
        _ = try await WeChatShortcutNavigation.run(initial: transferChat(), name: "文件传输助手", stableID: "wechat.builtin.file-transfer",
            tap: { tapped.append($0.id) }, read: { fatalError("already open must not read") })
        precondition(tapped.isEmpty, "verified current chat never taps")
        for initial in [frame("wechat.list", []), frame("wechat.list", [row, e("duplicate", "文件传输助手", 0.5, 0.4)])] {
            tapped = []
            do {
                _ = try await WeChatShortcutNavigation.run(initial: initial, name: "文件传输助手", stableID: "wechat.builtin.file-transfer",
                    tap: { tapped.append($0.id) }, read: { fatalError("ambiguous target must not read") })
                fatalError("missing or duplicate row must fail")
            } catch { precondition(tapped.isEmpty, "missing/duplicate rows must not be tapped") }
        }
        tapped = []
        do {
            _ = try await WeChatShortcutNavigation.run(initial: list, name: "文件传输助手", stableID: "wechat.builtin.file-transfer",
                tap: { tapped.append($0.id) }, read: { frame("unknown", []) })
            fatalError("unverified post-tap page must fail")
        } catch { precondition(tapped == ["row"], "post-tap failure must stop without extra input") }
        let account = try WeChatContactIdentity.stableID(account: "wxid_fixtureK")
        let profile = frame("unknown", [e("back", "通讯录", 0.1, 0.07), e("name", "Synthetic contact", 0.5, 0.18),
            e("account", "微信号：wxid_fixtureK", 0.55, 0.25, 0.65), e("moments", "朋友圈", 0.25, 0.48),
            e("message", "发消息", 0.5, 0.7), e("call", "音视频通话", 0.5, 0.8)])
        tapped = []
        let other = try WeChatContactIdentity.stableID(account: "wxid_otherK")
        do {
            _ = try await WeChatShortcutNavigation.run(initial: profile, name: "Synthetic contact", stableID: other,
                tap: { tapped.append($0.id) }, read: { fatalError("mismatch must not read") })
            fatalError("wrong account must fail")
        } catch { precondition(tapped.isEmpty, "wrong account must not tap") }
        tapped = []
        _ = try await WeChatShortcutNavigation.run(initial: profile, name: "Synthetic contact", stableID: account,
            tap: { tapped.append($0.id) }, read: {
                frame("wechat.chat", [e("back", "微信", 0.1, 0.08), e("title", "Synthetic contact", 0.5, 0.08),
                    e("input", "发送消息", 0.4, 0.9)], capturedAt: Date().addingTimeInterval(0.1))
            })
        precondition(tapped == ["message"], "matching profile only taps message control")
        print("WeChat shortcut: 6 offline navigation scenarios passed; no device interaction")
    }
}
