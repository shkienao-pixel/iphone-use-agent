import Foundation

struct PhoneOverlayAssessment: Equatable {
    enum Kind: String { case none, sensitiveDialog, uncertainControl, cancelMenu, agentOverlay }
    var kind: Kind
    var evidenceIDs: [String]
    var reason: String
    var blocking: Bool { kind != .none }
}

/// A local observation classifier, never permission to confirm a dialog.
/// Sensitive words are interpreted in their observed UI and pixel context.
/// Unknown controls remain blocked; recognizing a chat/note never excludes
/// overlays for that entire page. There are no model-supplied visual labels.
enum PhoneOverlayClassifier {
    private static let permissions: Set<String> = ["allow", "don't allow", "don’t allow", "允许", "不允许", "允许一次", "仅允许一次", "使用app时允许", "使用应用时允许", "allow once", "allow while using app", "allow while using the app", "始终允许"]
    private static let confirmations: Set<String> = ["ok", "确定", "确认", "好", "同意", "agree"]
    private static let cancel: Set<String> = ["取消", "cancel"]
    private static let highRisk: Set<String> = ["确认付款", "确认支付", "付款", "支付", "pay", "pay now", "face id", "faceid", "面容id", "面容 id", "touch id", "触控id", "触控 id", "enter passcode", "enter your passcode", "输入密码", "请输入密码", "支付密码", "输入支付密码", "请输入支付密码", "删除聊天", "删除", "确认删除", "是否删除", "delete", "delete chat", "重新发送", "确认重新发送", "重发", "resend", "登录", "重新登录", "确认登录", "是否登录", "log in", "login", "sign in", "是否发送", "确认发送", "发送确认"]
    private static let permissionPhrases = ["想访问", "想要访问", "请求访问", "访问你的照片", "访问您的照片", "访问你的相机", "访问您的相机", "使用你的麦克风", "使用您的麦克风", "would like to access", "would like to use", "permission required", "允许访问"]

    static func evaluate(elements: [PhoneUIElement], raster: PhoneRasterImage? = nil,
                         ignoringMenuCancel: Bool = false) -> PhoneOverlayAssessment {
        let ocr = elements.filter { $0.source == "ocr" }
        func result(_ kind: PhoneOverlayAssessment.Kind, _ values: [PhoneUIElement], _ reason: String) -> PhoneOverlayAssessment {
            .init(kind: kind, evidenceIDs: values.map(\.id), reason: reason)
        }
        if let own = ocr.first(where: { $0.label.contains("Sela ·") || $0.label.contains("Phone Agent ·") }) {
            return result(.agentOverlay, [own], "当前有 Sela 动作浮窗")
        }
        let actions = ocr.filter { action(normalized($0.label)) }
        let phrases = ocr.filter { permissionPhrase(normalized($0.label)) }
        let cancels = ocr.filter { cancel.contains(normalized($0.label)) && (!$0.rect.valid || $0.rect.centerY >= 0.18) }
        let relevant = actions + phrases + cancels
        if let invalid = relevant.first(where: { !$0.rect.valid }) {
            return result(.uncertainControl, [invalid], "敏感文字缺少可信位置，未排除确认控件")
        }
        // A real button pair/card remains blocked even when the underlying
        // chat title and composer are also visible behind it.
        let buttons = actions + cancels
        for first in buttons {
            for second in buttons where second.id != first.id {
                guard centralButton(first.rect), centralButton(second.rect) else { continue }
                let firstLabel = normalized(first.label), secondLabel = normalized(second.label)
                guard firstLabel != secondLabel else { continue }
                let horizontal = abs(first.rect.centerY - second.rect.centerY) < 0.045 && abs(first.rect.centerX - second.rect.centerX) > 0.16
                let vertical = abs(first.rect.centerX - 0.5) < 0.18 && abs(second.rect.centerX - 0.5) < 0.18 &&
                    abs(first.rect.centerX - second.rect.centerX) < 0.12 && (0.025...0.23).contains(abs(first.rect.centerY - second.rect.centerY))
                if horizontal || vertical {
                    return result(.sensitiveDialog, [first, second], "当前中央/底部存在确认、权限或危险操作按钮组合")
                }
            }
        }
        for phrase in phrases where dialogArea(phrase.rect) {
            if let button = buttons.first(where: { centralButton($0.rect) && $0.rect.centerY >= phrase.rect.centerY - 0.025 && $0.rect.centerY <= phrase.rect.centerY + 0.38 }) {
                return result(.sensitiveDialog, [phrase, button], "权限说明与当前确认控件同时出现")
            }
        }
        let page = contentPage(elements: elements)
        for element in actions + phrases {
            if ordinaryContent(element, page: page, elements: elements, raster: raster) { continue }
            let label = normalized(element.label)
            return result(highRisk.contains(label) || permissionPhrase(label) ? .sensitiveDialog : .uncertainControl,
                [element], "当前敏感文字尚不能证明属于普通正文，保留弹窗阻挡")
        }
        if !ignoringMenuCancel {
            for element in cancels {
                if ordinaryContent(element, page: page, elements: elements, raster: raster) { continue }
                return result(.cancelMenu, [element], "取消菜单/未知浮层需由专属流程独立核对")
            }
        }
        return .init(kind: .none, evidenceIDs: [], reason: "未发现待阻挡确认控件；这不证明所有未知弹窗均已识别")
    }

    private static func normalized(_ text: String) -> String { PhonePageAdapters.normalized(text) }
    private static func permissionPhrase(_ text: String) -> Bool { permissionPhrases.contains { text.contains($0) } }
    private static func action(_ text: String) -> Bool {
        permissions.contains(text) || confirmations.contains(text) || highRisk.contains(text) ||
            text.hasPrefix("请输入支付密码") || text.hasPrefix("输入支付密码") || text.hasPrefix("请输入密码") || text.hasPrefix("输入密码") || text.hasPrefix("enter passcode") || text.hasPrefix("enter your passcode")
    }
    private static func centralButton(_ rect: PhoneUIRect) -> Bool {
        rect.valid && (0.20...0.94).contains(rect.centerY) && (0.18...0.82).contains(rect.centerX)
    }
    private static func dialogArea(_ rect: PhoneUIRect) -> Bool {
        rect.valid && (0.18...0.88).contains(rect.centerY) && (0.30...0.70).contains(rect.centerX)
    }

    private static func contentPage(elements: [PhoneUIElement]) -> PhonePageIdentity? {
        let probe = PhoneUISnapshot(deviceKey: "overlay-role-only", scene: "unknown", elements: elements, capturedAt: Date())
        if let page = PhonePageAdapters.identity(in: probe), ["wechat.chat", "xiaohongshu.note"].contains(page.scene) { return page }
        // Empty WeChat composers have no OCR placeholder. These current pixel
        // symbols establish a body region only, never app/account identity.
        let titles = elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY < 0.16 && (0.28...0.76).contains($0.rect.centerX) }
        func one(_ label: String, _ area: (PhoneUIRect) -> Bool) -> PhoneUIElement? {
            let values = elements.filter { $0.source == "local_visual" && $0.rect.valid && $0.label == label && area($0.rect) }
            return values.count == 1 ? values[0] : nil
        }
        guard titles.count == 1, let back = one("视觉:返回", { $0.centerX < 0.18 && $0.centerY < 0.16 }),
              let more = one("视觉:更多", { $0.centerX > 0.8 && $0.centerY < 0.16 }),
              let plus = one("视觉:添加", { $0.centerX > 0.8 && (0.55...0.96).contains($0.centerY) }) else { return nil }
        return .init(scene: "wechat.chat", evidence: [titles[0].id, back.id, more.id, plus.id], conversation: titles[0].label,
            messages: elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY > 0.18 && $0.rect.centerY < plus.rect.y - 0.025 })
    }

    private static func ordinaryContent(_ element: PhoneUIElement, page: PhonePageIdentity?, elements: [PhoneUIElement], raster: PhoneRasterImage?) -> Bool {
        guard let page, let raster, raster.valid else { return false }
        if page.scene == "wechat.chat", page.messages.contains(where: { $0.id == element.id }),
           element.rect.centerX < 0.4 || element.rect.centerX > 0.6 {
            return bubblePixels(element.rect, raster: raster)
        }
        guard page.scene == "xiaohongshu.note", (0.24...0.78).contains(element.rect.centerY), element.rect.x < 0.15 else { return false }
        let neighboringLines = elements.filter {
            $0.source == "ocr" && $0.rect.valid && $0.id != element.id &&
            (0.24...0.78).contains($0.rect.centerY) && abs($0.rect.x - element.rect.x) < 0.03 &&
            (0.025...0.18).contains(abs($0.rect.centerY - element.rect.centerY)) &&
            !action(normalized($0.label)) && !cancel.contains(normalized($0.label)) && !permissionPhrase(normalized($0.label))
        }
        return neighboringLines.count >= 2 && documentPixels(element.rect, raster: raster)
    }

    private static func color(_ raster: PhoneRasterImage, _ x: Double, _ y: Double) -> PhoneRasterPixel? {
        guard let sample = raster.sample(x, y), sample.alpha > 0.95 else { return nil }; return sample
    }
    private static func difference(_ a: PhoneRasterPixel, _ b: PhoneRasterPixel) -> Double {
        max(abs(a.red - b.red), max(abs(a.green - b.green), abs(a.blue - b.blue)))
    }
    private static func bubblePixels(_ rect: PhoneUIRect, raster: PhoneRasterImage) -> Bool {
        guard rect.width <= 0.65, rect.height <= 0.12,
              let ambient = color(raster, 0.5, rect.centerY),
              let left = color(raster, 0.02, rect.centerY), let right = color(raster, 0.98, rect.centerY),
              difference(left, ambient) < 0.045, difference(right, ambient) < 0.045 else { return false }
        let insidePoints = [rect.x - 0.01, rect.centerX, rect.x + rect.width + 0.01].flatMap { x in
            [(x, rect.y - 0.009), (x, rect.y + rect.height + 0.009)]
        }
        let inside = insidePoints.compactMap { color(raster, $0.0, $0.1) }
        guard inside.count == insidePoints.count, let bubble = inside.first,
              inside.allSatisfy({ difference($0, bubble) < 0.045 }), difference(bubble, ambient) >= 0.065 else { return false }
        func findsBackground(_ originX: Double, _ originY: Double, _ dx: Double, _ dy: Double) -> Bool {
            (1...14).contains { step in
                color(raster, originX + Double(step) * dx, originY + Double(step) * dy).map { difference($0, ambient) < 0.045 } ?? false
            }
        }
        return findsBackground(rect.x - 0.01, rect.centerY, -0.008, 0) &&
            findsBackground(rect.x + rect.width + 0.01, rect.centerY, 0.008, 0) &&
            findsBackground(rect.centerX, rect.y - 0.009, 0, -0.006) &&
            findsBackground(rect.centerX, rect.y + rect.height + 0.009, 0, 0.006)
    }
    private static func documentPixels(_ rect: PhoneUIRect, raster: PhoneRasterImage) -> Bool {
        let points = [(0.02, rect.centerY), (0.98, rect.centerY), (0.02, 0.23), (0.98, 0.23),
                      (0.02, 0.81), (0.98, 0.81), (rect.x - 0.01, rect.centerY), (rect.x + rect.width + 0.01, rect.centerY)]
        let samples = points.compactMap { color(raster, $0.0, $0.1) }
        guard samples.count == points.count, let background = samples.first else { return false }
        return samples.allSatisfy { difference($0, background) < 0.035 }
    }
}
