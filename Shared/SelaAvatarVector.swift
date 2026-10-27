import SwiftUI

enum SelaAvatarVector {
    struct Node: Decodable {
        let tag: String
        let attributes: [String: String]
        let children: [Node]
    }
    static let expressions: [String: Node] = {
        guard let url = Bundle.main.url(forResource: "SelaExpressions", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String: Node].self, from: data) else { return [:] }
        return value
    }()
    /// Optional pose matches the approved island preview without changing the
    /// neutral expression used elsewhere in the app.
    struct Pose {
        var gazeTranslation: CGPoint = .zero
        var gazeScale: CGSize = CGSize(width: 1, height: 1)
        var browTranslation: CGPoint = .zero
        static let neutral = Pose()
    }
    static func draw(_ name: String, context: inout GraphicsContext, pose: Pose = .neutral) {
        if let node = expressions[name] { draw(node, context: &context, pose: pose) }
    }
    private static func draw(_ node: Node, context: inout GraphicsContext, pose: Pose) {
        var local = context
        let a = node.attributes
        let classes = a["class"] ?? ""
        if classes.split(separator: " ").contains("avatar-gaze") {
            local.translateBy(x: pose.gazeTranslation.x, y: pose.gazeTranslation.y)
            local.scaleBy(x: pose.gazeScale.width, y: pose.gazeScale.height)
        }
        if classes.split(separator: " ").contains("avatar-brows") {
            local.translateBy(x: pose.browTranslation.x, y: pose.browTranslation.y)
        }
        if let transform = a["transform"], transform.hasPrefix("rotate") {
            let n = numbers(transform)
            if n.count == 3 {
                local.translateBy(x: n[1], y: n[2]); local.rotate(by: .degrees(n[0])); local.translateBy(x: -n[1], y: -n[2])
            }
        }
        if node.tag == "g" { for child in node.children { draw(child, context: &local, pose: pose) }; return }
        let path: Path
        if node.tag == "ellipse" {
            let cx = Double(a["cx"] ?? "0") ?? 0, cy = Double(a["cy"] ?? "0") ?? 0
            let rx = Double(a["rx"] ?? "0") ?? 0, ry = Double(a["ry"] ?? "0") ?? 0
            path = Path(ellipseIn: CGRect(x: cx-rx, y: cy-ry, width: rx*2, height: ry*2))
        } else if node.tag == "path" { path = svgPath(a["d"] ?? "") }
        else { return }
        let isFillPath = classes.contains("brow-fill") || classes.contains("smile-fill")
        let fill = a["stroke"] != nil ? "none" : (a["fill"] ?? (node.tag == "path" && !isFillPath ? "none" : "#38414e"))
        local.opacity = Double(a["opacity"] ?? "1") ?? 1
        if fill != "none" { local.fill(path, with: shading(fill, path: path, classes: classes)) }
        if node.tag == "path" && !isFillPath || a["stroke"] != nil {
            local.stroke(path, with: shading(a["stroke"] ?? "#38414e", path: path, classes: classes), style: StrokeStyle(lineWidth: classes.contains("focus-mark") ? 2.5 : 3.8, lineCap: .round, lineJoin: .round))
        }
    }
    private static func shading(_ value: String, path: Path, classes: String) -> GraphicsContext.Shading {
        let colors: [Color]?
        if value.contains("EyeInk") {
            colors = [Color(red: 105.0 / 255, green: 113.0 / 255, blue: 125.0 / 255), Color(red: 26.0 / 255, green: 34.0 / 255, blue: 42.0 / 255)]
        } else if value.contains("BrowInk") {
            colors = [Color(red: 74.0 / 255, green: 78.0 / 255, blue: 84.0 / 255), Color(red: 48.0 / 255, green: 54.0 / 255, blue: 61.0 / 255)]
        } else if value.contains("MouthInk") {
            colors = [Color(red: 102.0 / 255, green: 80.0 / 255, blue: 74.0 / 255), Color(red: 53.0 / 255, green: 45.0 / 255, blue: 43.0 / 255)]
        } else { colors = nil }
        guard let colors else { return .color(color(value, classes: classes)) }
        return .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: path.boundingRect.midX, y: path.boundingRect.minY), endPoint: CGPoint(x: path.boundingRect.midX, y: path.boundingRect.maxY))
    }
    private static func color(_ value: String, classes: String) -> Color {
        if value.contains("Shadow") { return Color.brown.opacity(0.09) }
        if value.contains("Cheek") { return Color(red: 0.92, green: 0.7, blue: 0.6).opacity(0.2) }
        if value.hasPrefix("#"), let hex = UInt32(value.dropFirst(), radix: 16) {
            return Color(red: Double(hex >> 16 & 255)/255, green: Double(hex >> 8 & 255)/255, blue: Double(hex & 255)/255)
        }
        return Color(red: 0.24, green: 0.27, blue: 0.32)
    }
    private static func numbers(_ text: String) -> [Double] {
        text.components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted).compactMap(Double.init)
    }
    private static func svgPath(_ text: String) -> Path {
        let regex = try! NSRegularExpression(pattern: "([A-Za-z])([^A-Za-z]*)")
        let source = text as NSString
        var path = Path()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let command = source.substring(with: match.range(at: 1)), n = numbers(source.substring(with: match.range(at: 2)))
            switch command {
            case "M" where n.count >= 2: path.move(to: CGPoint(x: n[0], y: n[1]))
            case "Q":
                for i in stride(from: 0, to: n.count-3, by: 4) { path.addQuadCurve(to: CGPoint(x: n[i+2], y: n[i+3]), control: CGPoint(x: n[i], y: n[i+1])) }
            case "C":
                for i in stride(from: 0, to: n.count-5, by: 6) { path.addCurve(to: CGPoint(x: n[i+4], y: n[i+5]), control1: CGPoint(x: n[i], y: n[i+1]), control2: CGPoint(x: n[i+2], y: n[i+3])) }
            case "L" where n.count >= 2: path.addLine(to: CGPoint(x: n[0], y: n[1]))
            case "h" where !n.isEmpty: if let point = path.currentPoint { path.addLine(to: CGPoint(x: point.x+n[0], y: point.y)) }
            case "m" where n.count >= 2: if let point = path.currentPoint { path.move(to: CGPoint(x: point.x+n[0], y: point.y+n[1])) }
            case "Z", "z": path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
