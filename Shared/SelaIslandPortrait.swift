import SwiftUI

/// The original Sela portrait, shared by the app and its real Live Activity.
struct SelaIslandPortrait: View {
    let phase: String
    var width: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expression: String {
        switch phase {
        case "observing", "thinking", "planning": "thinking"
        case "acting": "working"
        case "awaitingApproval", "needsUser": "waiting"
        case "completed": "happy"
        case "paused", "stopped": "rest"
        case "failed": "concern"
        default: "open"
        }
    }
    private var scale: CGFloat { width / 88 }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("SelaHeadTexture").renderingMode(.original).resizable().scaledToFit()
                .frame(width: 116 * scale, height: 116 * scale).offset(x: -1.4 * scale, y: -4 * scale)
            Canvas { context, size in
                context.scaleBy(x: size.width / 100, y: size.height / 100)
                SelaAvatarVector.draw(expression, context: &context)
            }.frame(width: 80 * scale, height: 80 * scale).offset(x: 18 * scale, y: 31 * scale)
        }
        .frame(width: 116 * scale, height: 116 * scale)
        .frame(width: width, height: width * 116 / 88)
        .phaseAnimator([0, 1, 2], trigger: phase) { portrait, moment in
            portrait
                .rotationEffect(.degrees(reduceMotion ? 0 : tilt(moment)))
                .offset(y: reduceMotion || moment != 1 ? 0 : (phase == "completed" ? -3 : -1))
        } animation: { _ in .easeInOut(duration: reduceMotion ? 0 : 0.45) }
        .accessibilityHidden(true)
    }
    private func tilt(_ moment: Int) -> Double {
        guard moment == 1 else { return 0 }
        switch phase {
        case "observing", "thinking", "planning": return -5
        case "awaitingApproval", "needsUser": return 5
        case "failed": return -4
        default: return 0
        }
    }
}
