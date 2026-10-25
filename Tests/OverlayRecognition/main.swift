import Foundation
import CoreGraphics

struct OverlayRasterFixture {
    var width = 320, height = 640
    var bytes: [UInt8]
    init(_ value: UInt8 = 237) {
        bytes = [UInt8](repeating: value, count: 320 * 640 * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
    }
    mutating func fill(_ rect: PhoneUIRect, _ color: (UInt8, UInt8, UInt8)) {
        for y in Int(rect.y * Double(height))..<min(height, Int((rect.y + rect.height) * Double(height))) {
            for x in Int(rect.x * Double(width))..<min(width, Int((rect.x + rect.width) * Double(width))) {
                guard x >= 0, y >= 0 else { continue }; let offset = (y * width + x) * 4
                bytes[offset] = color.0; bytes[offset + 1] = color.1; bytes[offset + 2] = color.2
            }
        }
    }
    mutating func glyphs(omitting: Set<String> = []) {
        func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
        var points: [(Int, Int)] = []
        if !omitting.contains("视觉:返回") { for y in 44...62 { let x = 14 + abs(y - 53); points += [(x,y),(x+1,y)] } }
        if !omitting.contains("视觉:更多") { for center in [281,288,295] { for y in 50...52 { for x in (center-1)...(center+1) { points.append((x,y)) } } } }
        if !omitting.contains("视觉:添加") { for y in 580...600 { for x in 279...299 {
            let dx = Double(x-289)/10, dy = Double(y-590)/10
            if abs(hypot(dx,dy)-0.94)<0.09 || (abs(dx)<0.11 && abs(dy)<0.61) || (abs(dy)<0.11 && abs(dx)<0.61) { points.append((x,y)) }
        } } }
        for point in points { let i=index(point.0,point.1); bytes[i]=10;bytes[i+1]=10;bytes[i+2]=10 }
    }
    var raster: PhoneRasterImage { .init(width: width, height: height, rgba: bytes) }
    var image: CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

@MainActor final class OverlayReplay {
    let captureID = UUID()
    var observations: [Date: [PhoneUIElement]] = [:]
    func frame(_ elements: [PhoneUIElement], _ raster: OverlayRasterFixture) -> ScreenFrame {
        let frame = ScreenFrame(image: UIImage(cgImage: raster.image), captureID: captureID)
        observations[frame.capturedAt] = elements; return frame
    }
    func recognize(_ frame: ScreenFrame) throws -> [PhoneUIElement] {
        guard let elements = observations[frame.capturedAt] else { throw AgentError.message("Missing fixture OCR") }; return elements
    }
}

@main struct OverlayRecognitionChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        func element(_ id: String, _ text: String, _ x: Double, _ y: Double, width: Double = 0.08, height: Double = 0.025) -> PhoneUIElement {
            .init(id: id, label: text, rect: .init(x: x - width / 2, y: y - height / 2, width: width, height: height), source: "ocr")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chatHeader = [element("back", "微信", 0.1, 0.08), element("title", "文件传输助手", 0.5, 0.08), element("input", "发送消息", 0.4, 0.9)]
        func bubble(_ text: String, outgoing: Bool = true, dark: Bool = false) -> ([PhoneUIElement], OverlayRasterFixture) {
            var pixels = OverlayRasterFixture(dark ? 25 : 237)
            let x = outgoing ? 0.75 : 0.25
            pixels.fill(.init(x: x - 0.08, y: 0.365, width: 0.16, height: 0.07), outgoing ? (149, 237, 105) : (dark ? (49, 49, 49) : (255, 255, 255)))
            return (chatHeader + [element("body", text, x, 0.4)], pixels)
        }
        for word in ["OK", "确定", "允许", "不允许", "取消", "登录", "删除聊天", "重新发送", "输入密码", "确认付款"] {
            for outgoing in [true, false] {
                let (elements, pixels) = bubble(word, outgoing: outgoing)
                let assessment = PhoneOverlayClassifier.evaluate(elements: elements, raster: pixels.raster)
                expect(!assessment.blocking, "An actual \(outgoing ? "outgoing" : "incoming") message bubble containing \(word) is plain observed content")
            }
        }
        for dark in [false, true] {
            let (elements, pixels) = bubble("OK", outgoing: false, dark: dark)
            expect(!PhoneOverlayClassifier.evaluate(elements: elements, raster: pixels.raster).blocking, "Bubble geometry is evaluated from actual \(dark ? "dark" : "light") RGBA pixels")
        }
        let (plainChat, plainPixels) = bubble("OK")
        expect(PhoneOverlayClassifier.evaluate(elements: plainChat).blocking, "Chat scene and position alone cannot waive an unknown confirmation control without pixels")
        expect(PhoneOverlayClassifier.evaluate(elements: plainChat, raster: OverlayRasterFixture().raster).blocking, "A flat frame without an actual bubble does not prove the word belongs to a message")
        var noChat = plainChat; noChat.removeAll { $0.id == "input" }
        expect(PhoneOverlayClassifier.evaluate(elements: noChat, raster: plainPixels.raster).blocking, "A colored rectangle without a recognized body layout is not sufficient")
        var centerWord = plainChat; centerWord[centerWord.count - 1].rect.x = 0.46
        expect(PhoneOverlayClassifier.evaluate(elements: centerWord, raster: plainPixels.raster).blocking, "A central unknown OK does not inherit a side bubble's proof")

        let noteHeader = [element("brand", "小红书", 0.5, 0.05), element("follow", "关注", 0.88, 0.13), element("composer", "说点什么", 0.3, 0.92)]
        let noteLines = [element("line-before", "正文上文完整的一行", 0.26, 0.35, width: 0.38),
            element("word", "确定", 0.11, 0.4), element("line-after", "正文下文完整的一行", 0.26, 0.46, width: 0.38)]
        let notePixels = OverlayRasterFixture(250)
        expect(!PhoneOverlayClassifier.evaluate(elements: noteHeader + noteLines, raster: notePixels.raster).blocking,
            "Left-aligned continuous note text on the actual uniform document canvas does not become a dialog solely because it says 确定")
        expect(PhoneOverlayClassifier.evaluate(elements: noteHeader + [noteLines[1]], raster: notePixels.raster).blocking,
            "A standalone note word without adjacent paragraph evidence stays unknown")
        expect(PhoneOverlayClassifier.evaluate(elements: noteLines, raster: notePixels.raster).blocking,
            "Unidentified text rows cannot waive a confirmation word as a note")
        for word in ["OK", "允许", "不允许", "取消", "确认付款", "输入密码", "删除聊天", "重新发送", "登录"] {
            var lines = noteLines; lines[1].label = word
            expect(!PhoneOverlayClassifier.evaluate(elements: noteHeader + lines, raster: notePixels.raster).blocking,
                "A literal note paragraph word \(word) remains content when current layout and actual document pixels establish that role")
        }

        let permission = [element("permission-title", "微信想访问您的照片", 0.5, 0.42, width: 0.5),
            element("deny", "不允许", 0.3, 0.6), element("allow", "允许", 0.7, 0.6)]
        let permissionResult = PhoneOverlayClassifier.evaluate(elements: chatHeader + permission, raster: plainPixels.raster)
        expect(permissionResult.blocking && permissionResult.kind == .sensitiveDialog, "Permission button pair blocks even with a visible underlying chat")
        expect(PhoneOverlayClassifier.evaluate(elements: noteHeader + noteLines + permission, raster: notePixels.raster).blocking,
            "A note body cannot suppress a real permission title and button combination")
        for word in ["确认付款", "Face ID", "面容 ID", "输入密码", "输入密码以启用面容ID", "删除聊天", "重新发送", "重新登录", "登录", "是否发送", "OK", "确定", "允许"] {
            let controls = [element("danger", word, 0.5, 0.55), element("cancel", "取消", 0.5, 0.68)]
            let assessment = PhoneOverlayClassifier.evaluate(elements: chatHeader + controls, raster: plainPixels.raster, ignoringMenuCancel: true)
            expect(assessment.blocking, "Domain menu override never bypasses the actual \(word) confirmation/button combination")
        }
        for word in ["确认付款", "输入密码", "Face ID", "删除聊天", "重新发送", "登录", "OK", "确定", "允许"] {
            expect(PhoneOverlayClassifier.evaluate(elements: [element("unknown", word, 0.5, 0.5)]).blocking,
                "Isolated central \(word) remains conservatively blocked when surrounding dialog OCR is missing")
        }
        var modalPixels = OverlayRasterFixture(90)
        modalPixels.fill(.init(x: 0.12, y: 0.3, width: 0.76, height: 0.4), (250, 250, 250))
        modalPixels.fill(.init(x: 0.67, y: 0.365, width: 0.16, height: 0.07), (30, 170, 220))
        let rightModalButton = chatHeader + [element("modal-allow", "允许", 0.75, 0.4)]
        expect(PhoneOverlayClassifier.evaluate(elements: rightModalButton, raster: modalPixels.raster).blocking,
            "A small right-aligned button inside a dimmed dialog card is not mistaken for a chat bubble")
        var obscuredNotePixels = notePixels
        obscuredNotePixels.fill(.init(x: 0, y: 0, width: 1, height: 1), (90, 90, 90))
        obscuredNotePixels.fill(.init(x: 0.05, y: 0.3, width: 0.9, height: 0.4), (250, 250, 250))
        expect(PhoneOverlayClassifier.evaluate(elements: noteHeader + noteLines, raster: obscuredNotePixels.raster).blocking,
            "Dialog pixels over a note invalidate the ordinary-paragraph waiver even when old note anchors remain visible")
        let menu = [element("copy", "复制链接", 0.2, 0.65), element("cancel", "取消", 0.5, 0.9)]
        expect(PhoneOverlayClassifier.evaluate(elements: menu, raster: notePixels.raster).kind == .cancelMenu, "Generic Cancel menus continue to block generic GUI dispatch")
        expect(!PhoneOverlayClassifier.evaluate(elements: menu, raster: notePixels.raster, ignoringMenuCancel: true).blocking,
            "Only a separate domain policy may inspect a Cancel-only candidate")
        expect(PhoneOverlayClassifier.evaluate(elements: [element("own", "Phone Agent · 正在操作", 0.5, 0.2)], raster: notePixels.raster).blocking,
            "The assistant action overlay is always retained as blocking")
        var forged = permission; for i in forged.indices { forged[i].source = "model" }
        expect(!PhoneOverlayClassifier.evaluate(elements: forged, raster: notePixels.raster).blocking, "Model-authored strings are never promoted to observed UI evidence")
        var invalid = element("invalid", "允许", 0.5, 0.5); invalid.rect.width = -1
        expect(PhoneOverlayClassifier.evaluate(elements: [invalid], raster: notePixels.raster).blocking, "Invalid bounds do not waive sensitive text")

        // Actual production Runtime reads the fixture's CGImage and OCR seam,
        // runs raster conversion + overlay classification, then dispatches.
        let replay = OverlayReplay(), executor = MouseExecutor()
        let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: root.appendingPathComponent("layout.json"), recognize: replay.recognize)
        var recorded: [(Date, PhoneUISnapshot)] = []
        runtime.observationRecorder = { frame, snapshot in recorded.append((frame.capturedAt, snapshot)) }
        let clearFrame = replay.frame(plainChat, plainPixels)
        let clear = try await runtime.workflowSnapshot(clearFrame)
        expect(!clear.blockingOverlay, "The production Runtime clears the former isolated OK chat false positive using actual image pixels")
        expect(recorded.count == 1 && recorded[0].0 == clearFrame.capturedAt && recorded[0].1 == clear,
            "Observation recorder receives the unchanged actual frame timestamp and final snapshot once")
        _ = try await runtime.workflowSnapshot(clearFrame)
        expect(recorded.count == 1, "Cached OCR observations do not repeat diagnostic recording")
        let currentBody = clear.elements.first { $0.label == "OK" }!
        _ = try await runtime.execute(.init(operation: .tap, target: currentBody.id), frame: clearFrame, mappedHome: false, nextFrame: { _ in replay.frame(plainChat, plainPixels) })
        expect(executor.actions == [.tap], "Cleared plain content reaches the actual production local dispatch path")
        let blockedFrame = replay.frame(chatHeader + permission, plainPixels)
        let blocked = try await runtime.workflowSnapshot(blockedFrame, allowingMenu: { _ in true })
        expect(blocked.blockingOverlay, "Even an always-true domain menu policy cannot clear actual permission dialog evidence")
        var rejected = false
        do { _ = try await runtime.execute(.init(operation: .tap, target: blocked.elements.first { $0.label == "允许" }!.id), frame: blockedFrame, mappedHome: false, nextFrame: { _ in throw AgentError.message("unexpected read") }) }
        catch is PhoneHarnessFallback { rejected = true }
        expect(rejected && executor.actions == [.tap], "True permission overlay stops before any additional input")
        expect(recorded.count == 3 && recorded[2].1.blockingOverlay, "Recorder retains the true blocked observation rather than the domain menu copy")
        let emptyComposerElements = plainChat.filter { $0.id != "input" }
        var glyphPixels = plainPixels; glyphPixels.glyphs()
        let actualControls = PhoneVisualControls.detect(in: glyphPixels.raster)
        expect(actualControls.count == 3, "The empty-composer fixture produces all three actual production pixel detections")
        let emptyFrame = replay.frame(emptyComposerElements, glyphPixels)
        let empty = try await runtime.workflowSnapshot(emptyFrame)
        expect(!empty.blockingOverlay && empty.elements.filter { $0.source == "local_visual" }.count == 3,
            "Actual Runtime glyph detection establishes the empty composer's body role before clearing its proven OK bubble")
        var missingGlyphPixels = plainPixels; missingGlyphPixels.glyphs(omitting: ["视觉:更多"])
        let missingFrame = replay.frame(emptyComposerElements, missingGlyphPixels)
        expect(try await runtime.workflowSnapshot(missingFrame).blockingOverlay,
            "Missing one actual empty-composer glyph leaves the unknown OK blocked")
        print("OverlayRecognition: \(checks) checks passed (actual RGBA → production Runtime/classifier → guarded dispatch; offline fixtures only)")
    }
}
