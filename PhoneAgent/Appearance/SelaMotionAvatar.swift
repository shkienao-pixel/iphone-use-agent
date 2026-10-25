import SwiftUI

/// The approved SVG expressions rendered with native paths and the saved texture.
struct SelaMotionAvatar: View {
    let motion: String
    let dark: Bool
    let reduceMotion: Bool
    @State private var began = Date()
    private var expression: String {
        switch motion {
        case "listening": "listening"
        case "thinking": "thinking"
        case "acting": "working"
        case "awaitingApproval": "waiting"
        case "completed": "happy"
        case "paused", "stopped": "rest"
        case "failed": "concern"
        default: "open"
        }
    }
    private var label: String {
        switch motion {
        case "listening": "Listening"
        case "thinking": "Thinking"
        case "acting": "Working"
        case "preparing": "Preparing"
        case "awaitingApproval": "Confirm"
        case "completed": "Done"
        case "paused": "Paused"
        case "stopped": "Stopped"
        case "failed": "Retry"
        default: "Sela"
        }
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || (motion != "idle" && motion != "listening"))) { tick in
            let time = reduceMotion || (motion != "idle" && motion != "listening") ? 0 : tick.date.timeIntervalSince(began)
            let blink = !reduceMotion && time.truncatingRemainder(dividingBy: 6.8) > 6.6
            VStack(spacing: 2) {
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Image("SelaHeadTexture").resizable().scaledToFit()
                            .frame(width: 116, height: 116).offset(x: -1.4, y: -4)
                        Canvas { context, size in
                            context.scaleBy(x: size.width / 100, y: size.height / 100)
                            SelaAvatarVector.draw(blink ? "rest" : expression, context: &context)
                        }.frame(width: 80, height: 80).offset(x: 18, y: 31)
                    }
                    .frame(width: 116, height: 116)

                }.frame(width: 88, height: 116)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(SelaHomePalette.secondary)
            }.frame(width: 88, height: 132)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Sela，" + label)
    }
    func sized() -> some View { frame(width: 88, height: 132) }
}

