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
    static func draw(_ name: String, context: inout GraphicsContext) {
        if let node = expressions[name] { draw(node, context: &context) }
    }
    private static func draw(_ node: Node, context: inout GraphicsContext) {
        var local = context
        let a = node.attributes
        if let transform = a["transform"], transform.hasPrefix("rotate") {
            let n = numbers(transform)
            if n.count == 3 {
                local.translateBy(x: n[1], y: n[2]); local.rotate(by: .degrees(n[0])); local.translateBy(x: -n[1], y: -n[2])
            }
        }
        if node.tag == "g" { for child in node.children { draw(child, context: &local) }; return }
        let path: Path
        if node.tag == "ellipse" {
            let cx = Double(a["cx"] ?? "0") ?? 0, cy = Double(a["cy"] ?? "0") ?? 0
            let rx = Double(a["rx"] ?? "0") ?? 0, ry = Double(a["ry"] ?? "0") ?? 0
            path = Path(ellipseIn: CGRect(x: cx-rx, y: cy-ry, width: rx*2, height: ry*2))
        } else if node.tag == "path" { path = svgPath(a["d"] ?? "") }
        else { return }
        let classes = a["class"] ?? ""
        let isFillPath = classes.contains("brow-fill") || classes.contains("smile-fill")
        let fill = a["fill"] ?? (node.tag == "path" && !isFillPath ? "none" : "#38414e")
        local.opacity = Double(a["opacity"] ?? "1") ?? 1
        if fill != "none" {
            if fill.contains("EyeInk") {
                local.fill(path, with: .linearGradient(Gradient(colors: [Color(red: 0.41, green: 0.44, blue: 0.49), Color(red: 0.1, green: 0.13, blue: 0.16)]), startPoint: CGPoint(x: path.boundingRect.minX, y: path.boundingRect.minY), endPoint: CGPoint(x: path.boundingRect.maxX, y: path.boundingRect.maxY)))
            } else {
                local.fill(path, with: .color(color(fill, classes: classes)))
            }
        }
        if node.tag == "path" && !isFillPath || a["stroke"] != nil {
            local.stroke(path, with: .color(Color(red: 0.22, green: 0.25, blue: 0.3)), style: StrokeStyle(lineWidth: classes.contains("focus-mark") ? 2.5 : 3.8, lineCap: .round, lineJoin: .round))
        }
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
