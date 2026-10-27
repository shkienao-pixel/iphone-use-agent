import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct PhoneAgentActivityBundle: WidgetBundle {
    var body: some Widget { PhoneAgentActivityWidget() }
}
struct PhoneAgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenTaskActivity(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 14) {
                            SelaIslandPortrait(phase: TaskActivityPresentation.portraitPhase(phase: context.state.phase, isStale: context.isStale), width: 40, updatedAt: context.state.updatedAt)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Sela").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                                Text(context.state.isPreview == true ? (context.isStale ? "预览结束" : "角色预览") : TaskActivityPresentation.label(phase: context.state.phase, isStale: context.isStale)).font(.system(size: 19, weight: .semibold))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            Spacer(minLength: 4)
                            if !context.isStale && context.state.completed == true { ActivityStatusGlyph(completed: true) }
                            else if context.state.isPreview != true { Text("第 \(context.state.step) 步").font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.7)) }
                        }
                        Text(context.state.isPreview == true && context.isStale ? "预览已结束，返回 Sela 清理预览卡片" : context.isStale ? "状态暂未更新，打开 App 核对" : context.state.status)
                            .font(.system(size: 12)).lineLimit(1).foregroundStyle(.white.opacity(0.78)).invalidatableContent()
                        // A GUI task has no known total; don't invent a percentage.
                        Rectangle().fill(Color.white.opacity(0.17)).frame(height: 1)
                        ActivityTaskButtons(attributes: context.attributes, state: context.state, tint: .white)
                    }.padding(.horizontal, 4).padding(.bottom, 12)
                }
            } compactLeading: {
                SelaIslandPortrait(phase: TaskActivityPresentation.portraitPhase(phase: context.state.phase, isStale: context.isStale), width: 34, updatedAt: context.state.updatedAt)
            } compactTrailing: {
                if !context.isStale && context.state.completed == true { ActivityStatusGlyph(completed: true) }
                else { Text(context.state.isPreview == true ? (context.isStale ? "预览结束" : "角色预览") : TaskActivityPresentation.label(phase: context.state.phase, isStale: context.isStale)).font(.system(size: 11, weight: .medium)).fixedSize() }
            } minimal: {
                // Screen broadcasting can cause iOS to choose this presentation.
                // Carry the phase on the portrait itself; trailing text is absent.
                SelaIslandPortrait(phase: TaskActivityPresentation.portraitPhase(phase: context.state.phase, isStale: context.isStale), width: 34, updatedAt: context.state.updatedAt)
            }
            .widgetURL(context.state.isPreview == true ? URL(string: "phoneagent://activity-preview")! : TaskActivityLink.url(taskID: context.state.displayTaskID ?? context.attributes.taskID))
            .keylineTint(Color(red: 0.87, green: 0.85, blue: 0.77))
        }
    }
}

private struct LockScreenTaskActivity: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    private var dark: Bool { colorScheme == .dark || luminanceReduced }
    // Resolve the tint and ink from the same SwiftUI environment. UIKit's
    // systemBackground can resolve differently in a lock-screen snapshot.
    private var ink: Color { dark ? .white : Color(white: 0.10) }
    private var backgroundTint: Color {
        if reduceTransparency || luminanceReduced {
            return Color(white: dark ? 0.10 : 0.86)
        }
        return Color(white: dark ? 0.10 : 0.80).opacity(dark ? 0.64 : 0.68)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                SelaIslandPortrait(phase: TaskActivityPresentation.portraitPhase(phase: context.state.phase, isStale: context.isStale), width: 54, updatedAt: context.state.updatedAt)
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.state.taskTitle ?? "Sela").font(.headline).lineLimit(2)
                    Text(context.state.isPreview == true && context.isStale ? "预览已结束，返回 Sela 清理预览卡片" : context.isStale ? "状态暂未更新，打开 App 核对" : context.state.status)
                        .font(.subheadline).foregroundStyle(ink.opacity(0.90)).invalidatableContent()
                }
                Spacer()
                if !context.isStale && context.state.completed == true { ActivityStatusGlyph(completed: true) }
            }
            ActivityTaskButtons(attributes: context.attributes, state: context.state, tint: ink)
        }
        .padding(18).foregroundStyle(ink)
        .widgetURL(context.state.isPreview == true ? URL(string: "phoneagent://activity-preview")! : TaskActivityLink.url(taskID: context.state.displayTaskID ?? context.attributes.taskID))
        .activityBackgroundTint(backgroundTint)
        .activitySystemActionForegroundColor(ink)
    }
}

private struct ActivityTaskButtons: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    var tint: Color = .primary
    var body: some View {
        HStack(spacing: 8) {
            if let session = state.controlSessionID {
                if state.canPause == true {
                    Button(intent: PauseActivityPhoneTaskIntent(taskID: attributes.taskID, sessionID: session)) {
                        Label("暂停", systemImage: "pause.fill").frame(maxWidth: .infinity, minHeight: 28).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityHint("暂停此任务并保留进度，系统可能要求认证设备")
                }
                if state.canStop == true {
                    Button(intent: StopActivityPhoneTaskIntent(taskID: attributes.taskID, sessionID: session)) {
                        Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 28).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityHint("结束此任务，暂停队列并保留等待项，系统可能要求认证设备")
                }
            }
            Link(destination: state.isPreview == true ? URL(string: "phoneagent://activity-preview")! : TaskActivityLink.url(taskID: state.displayTaskID ?? attributes.taskID)) {
                Label(state.isPreview == true ? "返回 Sela" : "打开 App", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity, minHeight: 28).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }.accessibilityHint(state.isPreview == true ? "返回 Sela 并结束角色预览" : "回到 App 核对任务；打开不会自动继续")
        }.font(.system(size: 12, weight: .semibold)).buttonStyle(.plain).tint(tint).foregroundStyle(tint)
    }
}

private struct ActivityStatusGlyph: View {
    let completed: Bool
    var body: some View {
        if completed {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white).frame(width: 24, height: 24).background(.green, in: Circle())
        } else { SelaIslandPortrait(phase: "thinking", width: 22) }
    }
}

