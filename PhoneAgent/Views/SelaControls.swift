import SwiftUI

/// The mascot belongs to the conversation's scroll content, never its toolbar.
struct SelaConversationAvatar: View {
    let motion: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        SelaMotionAvatar(motion: motion, dark: colorScheme == .dark, reduceMotion: reduceMotion).sized()
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .accessibilityIdentifier("conversation.avatar")
    }
}

struct SelaTopChrome<Bar: View>: ViewModifier {
    let conversation: Bool
    private let background: Color
    private let bar: Bar
    init(conversation: Bool, background: Color = AgentPalette.background, @ViewBuilder bar: () -> Bar) {
        self.conversation = conversation; self.background = background; self.bar = bar()
    }
    @ViewBuilder func body(content: Content) -> some View {
        if conversation {
            content.safeAreaInset(edge: .top, spacing: 0) { bar }
                .overlay(alignment: .top) {
                    GeometryReader { geometry in
                        // Fade the page's own background; Material adds a
                        // pale tint that looks like a separate white panel.
                        Rectangle().fill(background)
                            .frame(height: geometry.safeAreaInsets.top)
                            .mask {
                                LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.52),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .top, endPoint: .bottom)
                            }
                            .offset(y: -geometry.safeAreaInsets.top)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
        } else {
            content.safeAreaBar(edge: .top, spacing: 0) { bar }
        }
    }
}

/// Keep one TextField instance while moving its controls to the second row.
/// Switching HStack/VStack branches would drop keyboard focus on the tap.
struct SelaComposerLayout: Layout {
    var expanded: Bool
    private let spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = max(160, proposal.width ?? 320)
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        let fieldWidth = expanded ? width : max(1, width - left.width - right.width - spacing * 2)
        let field = subviews[1].sizeThatFits(.init(width: fieldWidth, height: nil))
        let controlsHeight = max(left.height, right.height)
        return CGSize(width: width, height: expanded ? max(44, field.height) + spacing + controlsHeight : max(44, max(field.height, controlsHeight)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        let fieldWidth = expanded ? bounds.width : max(1, bounds.width - left.width - right.width - spacing * 2)
        let field = subviews[1].sizeThatFits(.init(width: fieldWidth, height: nil))
        let fieldHeight = max(44, field.height)
        if expanded {
            subviews[1].place(at: bounds.origin, proposal: .init(width: fieldWidth, height: fieldHeight))
            let y = bounds.minY + fieldHeight + spacing
            subviews[0].place(at: CGPoint(x: bounds.minX, y: y), proposal: .init(left))
            subviews[2].place(at: CGPoint(x: bounds.maxX - right.width, y: y), proposal: .init(right))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - left.height / 2), proposal: .init(left))
            subviews[1].place(at: CGPoint(x: bounds.minX + left.width + spacing, y: bounds.midY - fieldHeight / 2), proposal: .init(width: fieldWidth, height: fieldHeight))
            subviews[2].place(at: CGPoint(x: bounds.maxX - right.width, y: bounds.midY - right.height / 2), proposal: .init(right))
        }
    }
}

struct SelaMenuGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().frame(width: 20, height: 1.8)
            Capsule().frame(width: 12, height: 1.8)
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}
struct SelaScrollLatestButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down").font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().stroke(AgentPalette.ink.opacity(0.15), lineWidth: 0.7) }
        }.buttonStyle(.plain).foregroundStyle(AgentPalette.ink)
            .accessibilityLabel("回到最新消息").accessibilityIdentifier("conversation.scrollLatest")
    }
}
struct SelaAttachmentMenu: View {
    let onPhotos: () -> Void
    let onFiles: () -> Void
    @State private var open = false
    var body: some View {
        Button { open = true } label: { AgentComposerLeadingSlot() }
            .buttonStyle(.plain).accessibilityLabel("添加照片、视频或文件")
            .accessibilityIdentifier("composer.add")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                HStack(spacing: 12) {
                    attachment("照片与视频", icon: "photo.on.rectangle") { open = false; onPhotos() }
                    attachment("文件", icon: "folder") { open = false; onFiles() }
                }.padding(14).presentationCompactAdaptation(.popover)
            }
    }
    private func attachment(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: icon).font(.system(size: 28, weight: .light))
                Text(title).font(.subheadline.weight(.medium))
            }.frame(width: 112, alignment: .leading).padding(14)
                .background(AgentPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).foregroundStyle(AgentPalette.ink)
    }
}
