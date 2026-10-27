import SwiftUI

struct ToolsConnectionsView: View {
    let onNavigate: (WorkspaceDestination) -> Void
    @EnvironmentObject private var model: PhoneAgentViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 0) {
                    row("手机连接", detail: "辅助触控、配件、校准与屏幕共享", icon: "iphone.and.arrow.forward",
                        identifier: "tools.phoneConnections") { onNavigate(.phoneConnections) }
                    rowDivider
                    row("App 连接", detail: "管理外部应用与服务", icon: "square.stack.3d.up",
                        identifier: "tools.appConnections") { onNavigate(.appConnections) }
                    rowDivider
                    row("模型与记忆", detail: "配置 AI 服务与本机记忆", icon: "sparkles",
                        identifier: "tools.modelMemory") { onNavigate(.modelMemory) }
                }
                .background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 10) {
                    Text("功能体验").font(.footnote).foregroundStyle(SelaHomePalette.secondary)
                        .padding(.horizontal, 4)
                    row("打车模拟", detail: "在 Sela 内体验选点、接单与到达提醒", icon: "car.side",
                        identifier: "tools.didiSimulation") {
                            if model.conversation.startDidiSimulation() != nil { onNavigate(.assistant) }
                        }
                        .background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.primary)
        .background(SelaHomePalette.background.ignoresSafeArea())
        .accessibilityIdentifier("toolsConnections")
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(SelaHomePalette.line)
            .frame(height: 0.5)
            .padding(.leading, 64)
            .accessibilityHidden(true)
    }

    private func row(_ title: String, detail: String, icon: String, identifier: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 32, height: 36)
                    .foregroundStyle(SelaHomePalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(SelaHomePalette.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SelaHomePalette.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AgentPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
