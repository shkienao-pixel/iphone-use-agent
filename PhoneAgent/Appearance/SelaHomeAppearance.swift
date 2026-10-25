import SwiftUI
import UIKit

// A neutral task landing page; utility pages and the in-progress task canvas
// keep their existing appearance.
enum SelaHomePalette {
    static let background = adaptive(light: 0xFAFAFA, dark: 0x111111)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202020)
    static let accent = adaptive(light: 0x282828, dark: 0xEEEEEE)
    static let accentSurface = adaptive(light: 0xECECEC, dark: 0x2C2C2C)
    static let secondary = adaptive(light: 0x707070, dark: 0xAAAAAA)
    static let line = adaptive(light: 0xE6E6E6, dark: 0x363636)
    static let send = adaptive(light: 0x282828, dark: 0xEEEEEE)
    static let onSend = adaptive(light: 0xFFFFFF, dark: 0x171717)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct SelaHomeComposerSurface: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content
                .background(SelaHomePalette.surface, in: AgentInputMetrics.shape)
                .overlay { AgentInputMetrics.shape.stroke(SelaHomePalette.line, lineWidth: 1) }
                .shadow(color: SelaHomePalette.accent.opacity(0.06), radius: 16, y: 4)
        } else {
            content.agentGlass(in: AgentInputMetrics.shape)
        }
    }
}

struct SelaMascotHead: View {
    var size: CGFloat = 42
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The source is a transparent 512 × 512 full-body mascot. This region
    // contains its face; the circular mask excludes the curled tail and hands.
    private static let portrait: UIImage? = {
        guard let image = UIImage(named: "SelaMascot"), let source = image.cgImage else { return nil }
        let bounds = CGRect(x: CGFloat(source.width) * 0.352,
                            y: CGFloat(source.height) * 0.426,
                            width: CGFloat(source.width) * 0.363,
                            height: CGFloat(source.height) * 0.363).integral
        guard let head = source.cropping(to: bounds) else { return nil }
        return UIImage(cgImage: head, scale: image.scale, orientation: .up)
    }()

    var body: some View {
        ZStack {
            Circle().fill(SelaHomePalette.surface)
            if let portrait = Self.portrait {
                Image(uiImage: portrait).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
            } else {
                Image(systemName: "face.smiling").font(.system(size: size * 0.6))
                    .foregroundStyle(SelaHomePalette.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(SelaHomePalette.line, lineWidth: 1))
        .accessibilityLabel("Sela")
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

struct SelaHomeCanvas<Preparation: View>: View {
    let compact: Bool
    var onSuggestion: ((String) -> Void)? = nil
    @ViewBuilder let preparation: () -> Preparation
    @EnvironmentObject private var model: PhoneAgentViewModel
    @StateObject private var context = SelaHomeContext()

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: compact ? 16 : 28) {
                    if compact {
                        SelaConversationAvatar(motion: model.voiceMode != nil ? "listening" : "idle")
                    } else { introduction }
                    preparation()
                    if !compact && model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suggestions
                    }
                }
                .padding(.top, compact ? 12 : min(36, max(12, geometry.size.height * 0.04)))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { refreshContext() }
            .onChange(of: model.memories.records) { _, _ in refreshContext() }
            .onChange(of: model.settings.useMemories) { _, _ in refreshContext() }
        }
    }

    private var introduction: some View {
        VStack(spacing: 16) {
            Image("SelaMascot")
                .resizable().scaledToFit()
                .frame(width: 140, height: 140)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("今天，想做点什么？")
                    .font(.largeTitle.weight(.semibold))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.title")
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Text(context.greeting(at: tick.date))
                        .font(.subheadline)
                        .foregroundStyle(SelaHomePalette.secondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero")
    }

    private func refreshContext() {
        context.update(records: model.memories.records, enabled: model.settings.useMemories == true)
    }
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button { context.refresh() } label: { Label("换一组", systemImage: "arrow.triangle.2.circlepath") }
                    .font(.caption).foregroundStyle(SelaHomePalette.secondary).frame(minHeight: 44)
            }
            ForEach(context.suggestions) { item in
                Button {
                    if let onSuggestion { onSuggestion(item.prompt) } else { model.goal = item.prompt }
                } label: {
                    HStack(spacing: 12) {
                        Image("Hook-" + item.appId).resizable().scaledToFit()
                            .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline)
                            if let detail = item.memoryDetail, !detail.isEmpty {
                                Text("偏好：" + detail).font(.caption2).foregroundStyle(SelaHomePalette.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(SelaHomePalette.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(SelaHomePalette.accent)
                    .accessibilityIdentifier("home.hook." + item.id)
                    .accessibilityHint("填入草稿，确认后开始")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("home.suggestions")
    }

}
