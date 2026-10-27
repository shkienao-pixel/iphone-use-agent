import SwiftUI

/// The original Sela portrait, shared by the app and its real Live Activity.
/// Every status remains legible when the system renders only a static snapshot.
struct SelaIslandPortrait: View {
    let phase: String
    var width: CGFloat = 54
    var updatedAt: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    private enum State {
        case thinking, working, waiting, paused, completed, stale, failed, ready
    }
    private struct Update: Equatable {
        let phase: String
        let date: Date?
    }

    private var state: State {
        switch phase {
        case "preparing", "observing", "thinking", "planning": .thinking
        case "acting", "working": .working
        case "awaitingApproval", "needsUser": .waiting
        case "paused", "stopped": .paused
        case "completed": .completed
        case "stale": .stale
        case "failed": .failed
        default: .ready
        }
    }
    private var expression: String {
        switch state {
        case .thinking: "thinking"
        case .working: "working"
        case .waiting: "listening"
        case .paused: "rest"
        case .completed: "happy"
        case .stale, .failed: "concern"
        case .ready: "open"
        }
    }
    private var statusDescription: String {
        switch state {
        case .thinking: "思考中"
        case .working: "执行中"
        case .waiting: "等待你确认或操作"
        case .paused: phase == "stopped" ? "已停止" : "已暂停"
        case .completed: "已完成"
        case .stale: "状态暂未更新，打开 App 核对"
        case .failed: "执行遇到问题"
        case .ready: "已就绪"
        }
    }
    private var restingTilt: Double {
        switch state {
        case .thinking: -12
        case .waiting: 5
        case .paused: 9
        case .completed: -3
        case .stale, .failed: 6
        default: 0
        }
    }
    private var expressionPose: SelaAvatarVector.Pose {
        switch state {
        case .thinking: .init(gazeTranslation: CGPoint(x: -4, y: -5), browTranslation: CGPoint(x: 0, y: -3))
        case .working: .init(gazeTranslation: CGPoint(x: -4, y: 8), gazeScale: CGSize(width: 1.08, height: 0.83), browTranslation: CGPoint(x: 0, y: 3))
        case .waiting: .init(gazeTranslation: CGPoint(x: -5, y: -7), gazeScale: CGSize(width: 1.1, height: 1.1), browTranslation: CGPoint(x: 0, y: -5))
        default: .neutral
        }
    }
    private var restingScale: CGFloat {
        switch state {
        case .working, .waiting: 0.94
        case .paused: 0.89
        case .stale, .failed: 0.90
        default: 0.92
        }
    }
    private var restingOffset: CGFloat {
        switch state {
        case .waiting: -width * 0.02
        case .paused: width * 0.03
        default: 0
        }
    }
    private var canAnimate: Bool {
        !reduceMotion && !luminanceReduced && [.thinking, .working, .waiting, .completed].contains(state)
    }

    var body: some View {
        // A finite, sub-second reaction to genuine ActivityKit updates. There is
        // no timer, repeated background refresh, or dependency on endless motion.
        Color.clear
            .frame(width: width, height: width)
            .phaseAnimator([0, 1, 2, 3], trigger: Update(phase: phase, date: updatedAt)) { _, moment in
                ZStack(alignment: .topLeading) {
                    portrait
                        // The web preview had extra black space around its
                        // portrait. Reserve that space inside this native box.
                        .scaleEffect(1.33 * restingScale, anchor: UnitPoint(x: 0.53, y: 0.50))
                        .rotationEffect(.degrees(restingTilt + animatedTilt(moment)), anchor: UnitPoint(x: 0.53, y: 0.70))
                        .offset(y: restingOffset + animatedOffset(moment))
                        .opacity(state == .stale ? 0.78 : 1)
                    badge(moment: moment)
                }
                .frame(width: width, height: width)
            } animation: { _ in
                .easeInOut(duration: canAnimate ? 0.22 : 0)
            }
            // Keep all artwork and attached marks inside the system's region.
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sela，\(statusDescription)")
    }

    private var portrait: some View {
        ZStack(alignment: .topLeading) {
            Image("SelaHeadTexture")
                .renderingMode(.original).resizable().scaledToFit()
                .frame(width: width, height: width)
            Canvas { context, size in
                context.scaleBy(x: size.width / 100, y: size.height / 100)
                SelaAvatarVector.draw(expression, context: &context, pose: expressionPose)
            }
            .frame(width: width * 80 / 116, height: width * 80 / 116)
            .offset(x: width * 18 / 116, y: width * 31 / 116)
        }
        .frame(width: width, height: width)
    }

    @ViewBuilder private func badge(moment: Int) -> some View {
        switch state {
        case .thinking:
            // Draw the bubble and all dots in one fixed coordinate space. A
            // nested stack can inherit the portrait's transformed alignment.
            Canvas { context, size in
                let bubble = CGRect(x: size.width * 0.09, y: size.height * 0.10,
                                    width: size.width * 0.50, height: size.height * 0.26)
                let outline = Path(roundedRect: bubble, cornerRadius: bubble.height / 2)
                context.fill(outline, with: .color(.white))
                context.stroke(outline, with: .color(.black), lineWidth: max(0.6, size.width * 0.012))
                for index in 0..<3 {
                    var dotContext = context
                    dotContext.opacity = canAnimate && moment > 0 && moment != index + 1 ? 0.45 : 1
                    let diameter = size.width * 0.07
                    let dot = CGRect(x: bubble.midX + CGFloat(index - 1) * size.width * 0.12 - diameter / 2,
                                     y: bubble.midY - diameter / 2, width: diameter, height: diameter)
                    dotContext.fill(Path(ellipseIn: dot), with: .color(.black))
                }
            }
            .frame(width: width, height: width)
        case .working:
            // Keep the user's exact emoji, including its emoji presentation.
            // No blue disc, custom gear drawing, or replacement SF Symbol.
            Text("⚙️")
                .font(.system(size: width * 0.42))
                .fixedSize()
                .frame(width: width * 0.42, height: width * 0.42)
                .rotationEffect(.degrees(canAnimate ? Double(moment) * 60 : 0))
                .offset(x: width * 0.55, y: width * 0.57)
        case .paused:
            Circle().fill(Color(red: 1, green: 69.0 / 255, blue: 58.0 / 255))
                .overlay(Circle().stroke(.black, lineWidth: max(0.7, width * 0.02)))
                .frame(width: width * 0.25, height: width * 0.25)
                .offset(x: width * 0.61, y: width * 0.67)
        case .completed:
            statusMark("checkmark", color: Color(red: 48.0 / 255, green: 169.0 / 255, blue: 93.0 / 255))
        case .stale:
            statusMark("questionmark", color: Color(red: 244.0 / 255, green: 204.0 / 255, blue: 103.0 / 255), ink: Color(red: 53.0 / 255, green: 40.0 / 255, blue: 7.0 / 255))
        case .failed:
            statusMark("exclamationmark", color: .red)
        case .waiting, .ready:
            EmptyView()
        }
    }

    private func statusMark(_ symbol: String, color: Color, ink: Color = .white) -> some View {
        Image(systemName: symbol)
            .font(.system(size: width * 0.22, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: width * 0.32, height: width * 0.32)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.black, lineWidth: max(0.7, width * 0.02)))
            .offset(x: width * 0.54, y: width * 0.60)
    }

    private func animatedTilt(_ moment: Int) -> Double {
        guard canAnimate else { return 0 }
        switch state {
        case .thinking: return moment == 1 ? -8 : (moment == 2 ? 6 : 0)
        case .waiting: return moment == 1 ? 3 : 0
        default: return 0
        }
    }

    private func animatedOffset(_ moment: Int) -> CGFloat {
        guard canAnimate else { return 0 }
        switch state {
        case .working: return moment == 1 || moment == 3 ? width * 0.055 : 0
        case .completed, .waiting: return moment == 1 ? -width * 0.025 : 0
        default: return 0
        }
    }
}
