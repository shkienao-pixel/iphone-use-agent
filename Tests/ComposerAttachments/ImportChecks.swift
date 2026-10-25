import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

@main struct ImportChecks {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1])
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: " + name) }
        passed += 1
        print("PASS: " + name)
    }
    static func rejects(_ name: String, contains: String) async {
        do { _ = try await ComposerAttachmentImport.read(root.appendingPathComponent(name)); fatalError("Accepted " + name) }
        catch {
            let record: [String: String] = ["file": name, "expectedSubstring": contains,
                "errorType": String(reflecting: type(of: error)), "actualError": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent(name + ".rejection.json"), options: .atomic)
                if !error.localizedDescription.contains(contains) {
                    FileHandle.standardError.write(data + Data("\n".utf8))
                }
            }
            check(error.localizedDescription.contains(contains), name + " rejects with clear reason")
        }
    }
    static func makePDF(_ name: String, pages: Int, withText: Bool) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            if withText {
                let line = NSAttributedString(string: "Attachment PDF content", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
                context.textPosition = CGPoint(x: 40, y: 700)
                CTLineDraw(CTLineCreateWithAttributedString(line), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: root.appendingPathComponent(name))
    }
    @MainActor static func main() async throws {
        let utf8 = try await ComposerAttachmentImport.read(root.appendingPathComponent("utf8.txt"))
        check(utf8.text == "你好，附件\nLine two" && utf8.kind == .text, "UTF8 intact")
        let utf16 = try await ComposerAttachmentImport.read(root.appendingPathComponent("utf16.txt"))
        check(utf16.text == "UTF16 中文材料", "UTF16 BOM intact")
        let gb = try await ComposerAttachmentImport.read(root.appendingPathComponent("gb18030.txt"))
        check(gb.text == "中文编码测试，支持常用材料。", "GB18030 intact")
        let csv = try await ComposerAttachmentImport.read(root.appendingPathComponent("table.csv"))
        check(csv.text == "姓名,次数\n小王,2", "CSV intact")
        for (name, kind, text) in [("a.docx", ComposerAttachment.Kind.word, "Word 附件正文"), ("a.pptx", .slides, "第 1 页\n演示文稿第一页"), ("a.xlsx", .spreadsheet, "工作表：表一\n项目\t42")] {
            let attachment = try await ComposerAttachmentImport.read(root.appendingPathComponent(name))
            check(attachment.kind == kind && attachment.text.contains(text), name + " extracts content and kind")
        }
        for (name, expected) in [("empty.txt", "没有"), ("binary.txt", "编码"), ("broken.txt", "编码"), ("long.txt", "12000"), ("old.doc", ".docx"), ("unknown.zip", "暂支持"), ("large.txt", "5 MB")] { await rejects(name, contains: expected) }
        try makePDF("text.pdf", pages: 1, withText: true)
        let pdf = try await ComposerAttachmentImport.read(root.appendingPathComponent("text.pdf"))
        check(pdf.kind == .pdf && pdf.text.contains("Attachment PDF content"), "PDF extracts actual text")
        try makePDF("large.pdf", pages: 51, withText: false)
        await rejects("large.pdf", contains: "50")
        try makePDF("scans.pdf", pages: 11, withText: false)
        await rejects("scans.pdf", contains: "10")
        let context = CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8, bytesPerRow: 2400 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        let image = context.makeImage()!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        check(CGImageDestinationFinalize(destination), "Prepared image fixture")
        let photo = try await ComposerAttachmentImport.readImage(png as Data, name: "普通照片")
        check(photo.kind == .image && photo.text.isEmpty && photo.byteCount == png.length && photo.imageJPEG!.count <= 600000, "Photo without words survives as image")
        let output = CGImageSourceCreateWithData(photo.imageJPEG! as CFData, nil)!
        let outputImage = CGImageSourceCreateImageAtIndex(output, 0, nil)!
        check(max(outputImage.width, outputImage.height) <= 1600, "JPEG bounded at 1600 px")
        try (png as Data).write(to: root.appendingPathComponent("photo.png"))
        let filePhoto = try await ComposerAttachmentImport.read(root.appendingPathComponent("photo.png"))
        check(filePhoto.imageJPEG != nil && filePhoto.kind == .image, "Image file routes through visual importer")
        do { _ = try await ComposerAttachmentImport.readImage(Data(repeating: 1, count: 10000001), name: "过大图片"); fatalError("Oversized photo accepted") }
        catch { check(error.localizedDescription.contains("10 MB"), "Photo input limited at 10 MB") }
        do { _ = try await ComposerAttachmentImport.readImage(Data("invalid".utf8), name: "坏图"); fatalError("Invalid photo accepted") }
        catch { check(error.localizedDescription.contains("图片无效"), "Malformed image rejected") }
        let cancelled = Task {
            try Task.checkCancellation()
            return try await ComposerAttachmentImport.read(root.appendingPathComponent("utf8.txt"))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled import completed") }
        catch { check(error is CancellationError, "Cancelled import throws cancellation") }
        let store = ComposerAttachmentStore()
        store.importFiles(["utf8.txt", "old.doc", "table.csv"].map { root.appendingPathComponent($0) })
        while store.importing { try await Task.sleep(for: .milliseconds(20)) }
        check(store.items.count == 2 && store.error.contains("old.doc") && store.error.contains("docx"), "Batch keeps valid attachments and names rejection")
        store.importFiles(["utf8.txt", "table.csv", "a.docx"].map { root.appendingPathComponent($0) })
        check(!store.importing && store.items.count == 2 && store.error.contains("2"), "Batch count preflight preserves existing selection")
        let original = store.items
        store.replace([utf8, utf8])
        check(store.items == original && !store.error.isEmpty, "Invalid replacement preserves existing attachments")
        store.replace([photo])
        check(store.items == [photo] && store.error.isEmpty, "Valid replacement clears prior error")
        store.importFiles([root.appendingPathComponent("utf8.txt")])
        store.cancelImport()
        try await Task.sleep(for: .milliseconds(100))
        check(!store.importing && store.items == [photo], "Cancelled batch cannot append stale result")
        store.importFiles([root.appendingPathComponent("utf8.txt")])
        store.replace([csv])
        try await Task.sleep(for: .milliseconds(100))
        check(store.items == [csv], "Replacement generation blocks old append")
        store.remove(csv.id)
        check(store.items.isEmpty, "Remove targets selected attachment ID")
        store.replace([utf8])
        store.clear()
        check(store.items.isEmpty && store.error.isEmpty && !store.importing, "Clear resets items error and work")
        store.importFiles(["first.txt", "second.txt"].map { root.appendingPathComponent($0) })
        while store.importing { try await Task.sleep(for: .milliseconds(20)) }
        check(store.items.count == 1 && store.items[0].text.count == 7000 && store.error.contains("second.txt") && store.error.contains("12000"), "Aggregate text failure keeps earlier successful file without truncation")
        store.clear()
        print("\(passed) importer and store checks passed; all fixtures local, no model calls")
    }
}
