import SwiftUI
import UIKit

/// Starts a screen task; it is not a WeChat contact deep link.
struct WeChatShortcutView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var account = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AgentPageIntro(title: "打开微信聊天", subtitle: "先在微信打开好友资料页，再返回这里启动。", icon: "bubble.left.and.bubble.right")
                    TextField("好友的微信备注或名称", text: $name)
                        .agentField().accessibilityIdentifier("wechat.shortcut.name")
                    TextField("好友的微信号", text: $account)
                        .agentField().textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("wechat.shortcut.account")
                    Button("使用文件传输助手") {
                        name = "文件传输助手"; account = "filehelper"; error = ""
                    }.frame(minHeight: 44).accessibilityIdentifier("wechat.shortcut.filehelper")
                    Text("普通好友需要微信当前停在该人的资料页；文件传输助手可从聊天列表中可见的会话行进入。Sela 会核对画面后尝试打开聊天；无法确认身份或入口时停止。需要已连接配件、完成校准并开启整屏共享。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("此功能只点击经核对的会话行或资料页“发消息”，不会填写或发送消息。暂不支持自动搜索普通好友。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    Button("打开聊天") {
                        if let issue = model.startWeChatShortcut(name: name, account: account) {
                            error = issue
                        } else { dismiss() }
                    }
                    .buttonStyle(AgentButtonStyle())
                    .accessibilityIdentifier("wechat.shortcut.start")
                }.padding(20)
            }
            .navigationTitle("微信聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

extension PhoneAgentViewModel {
    /// Returns an error without replacing the user's existing task draft.
    func startWeChatShortcut(name: String, account: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.contains(where: \.isNewline),
              !account.isEmpty, account.count <= 80,
              account.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) }) else {
            return "请输入好友名称和准确的微信号。"
        }
        guard UIApplication.shared.applicationState == .active else { return "请返回 Sela 后重试。" }
        guard !engine.hasCurrentTask, !engine.running, !engine.releasing, !queueRunning,
              !preparingAutomatically, !queueSwitching, !voicePending, !calibrating, !manualBusy,
              !executor.calibrationInProgress, recordingAudioOwner == nil, !workflowServices.blocksGUI else {
            return "请先结束当前任务或其他操作，再打开聊天。"
        }
        guard capture.running, capture.frame?.fullDisplay == true, assistiveTouchReady, ble.ready, calibrationReady else {
            return "请先连接配件、完成校准并开启整屏共享。"
        }
        guard let wechatURL = URL(string: "weixin://") else { return "无法准备微信入口。" }
        let builtin = name == "文件传输助手" && account == "filehelper"
        let stableID: String
        if builtin { stableID = "wechat.builtin.file-transfer" }
        else {
            guard let validID = try? WeChatContactIdentity.stableID(account: account) else { return "请输入有效的微信号。" }
            stableID = validID
        }
        let operationID = UUID()
        manualAction(allowsBackgroundScreen: true, id: operationID) { [weak self] in
            guard let self else { return }
            let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "打开微信聊天") { [weak self] in
                self?.expireManualAction(id: operationID, message: "系统已结束本次后台运行，打开聊天已停止。")
            }
            guard backgroundID != .invalid else { throw AgentError.message("系统未提供后台运行时间，任务未启动。") }
            defer { UIApplication.shared.endBackgroundTask(backgroundID) }
            let gui = self.workflowServices.driver()
            guard await UIApplication.shared.open(wechatURL) else { throw AgentError.message("无法打开微信，请检查是否已安装。") }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let boundary = Date()
            let (frame, snapshot) = try await gui.read(after: boundary)
            func evidenceFrame(_ frame: ScreenFrame, _ snapshot: PhoneUISnapshot) throws -> WeChatShortcutFrame {
                guard let captureID = frame.captureID else { throw AgentError.message("共享画面无有效标识，已停止。") }
                return WeChatShortcutFrame(snapshot: snapshot, captureID: captureID,
                    frameID: "\(captureID.uuidString)-\(frame.capturedAt.timeIntervalSinceReferenceDate.bitPattern)",
                    confirmedAt: frame.confirmedAt)
            }
            _ = try await WeChatShortcutNavigation.run(initial: evidenceFrame(frame, snapshot), name: name, stableID: stableID,
                tap: { try await gui.tap($0) }, read: {
                    let (frame, snapshot) = try await gui.read()
                    return try evidenceFrame(frame, snapshot)
                })
            self.notice = builtin ? "已核对文件传输助手聊天窗口。" : "已核对并打开指定好友的聊天窗口。"
        }
        return nil
    }
}
