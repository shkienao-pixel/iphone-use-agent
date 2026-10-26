import SwiftUI

struct SidebarMainSurface: ViewModifier {
    let open: Bool
    var background: Color = AgentPalette.background
    var scrim: Color = .clear
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            let bottom = geometry.safeAreaInsets.bottom
            let fullHeight = geometry.size.height + top + bottom
            let shape = UnevenRoundedRectangle(topLeadingRadius: open ? 32 : 0,
                bottomLeadingRadius: open ? 32 : 0, style: .continuous)
            ZStack(alignment: .topLeading) {
                background.accessibilityHidden(true)
                // Preserve the content's original safe-area layout and keyboard
                // avoidance. Only its enclosing canvas extends to screen edges.
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(y: top)
                if open {
                    scrim.allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: fullHeight, alignment: .topLeading)
            .compositingGroup()
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                if open {
                    MainSurfaceLeadingEdge(radius: 32)
                        .stroke(AgentPalette.ink.opacity(colorScheme == .light ? 0.18 : 0.08),
                                style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .offset(y: -top)
        }
    }
}

private struct MainSurfaceLeadingEdge: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addCurve(to: CGPoint(x: 0, y: r),
                      control1: CGPoint(x: r * 0.46, y: 0),
                      control2: CGPoint(x: 0, y: r * 0.46))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: r, y: rect.maxY),
                      control1: CGPoint(x: 0, y: rect.maxY - r * 0.46),
                      control2: CGPoint(x: r * 0.46, y: rect.maxY))
        return path
    }
}
