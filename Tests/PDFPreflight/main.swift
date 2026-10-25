import Foundation
import CoreGraphics
import CoreText
import PDFKit

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

// Deliberately fail or return controlled text at the OCR boundary. PDFKit,
// file reads, scan classification, page/character limits and importer stay real.
final class OCRProbe: @unchecked Sendable {
    enum Result { case text, empty, failure, oversized }
    private let lock = NSLock()
    private var result: Result = .text
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func reset(_ result: Result) { lock.lock(); defer { lock.unlock() }; self.result = result; count = 0 }
    func recognize() throws -> String {
        lock.lock(); defer { lock.unlock() }; count += 1
        switch result {
        case .text: return "scanned-page-\(count)"
        case .empty: return ""
        case .failure: throw AgentError.message("Controlled OCR failure before scan limit")
        case .oversized: return String(repeating: "x", count: 12001)
        }
    }
}
enum LocalFileRecognition {
    static let probe = OCRProbe()
    static func scannedPage(_ page: PDFPage) throws -> String { try probe.recognize() }
    static func imageText(_ image: CGImage) throws -> String { throw AgentError.message("Unexpected image path in PDF-only fixture") }
}

@main struct PDFPreflightChecks {
    static func pdf(_ url: URL, pages: [String?]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        let target = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: target, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                for (index, value) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = NSAttributedString(string: String(value), attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 6, nil)])
                    context.textPosition = CGPoint(x: 40, y: 700 - Double(index) * 6.5)
                    CTLineDraw(CTLineCreateWithAttributedString(line), context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: url)
    }

    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var failures: [String] = [], checks = 0, errors: [[String: String]] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func rejected(_ name: String, pages: [String?], ocr: OCRProbe.Result, reason: String) async throws {
            let url = folder.appendingPathComponent(name)
            try pdf(url, pages: pages); LocalFileRecognition.probe.reset(ocr)
            do { _ = try await ComposerAttachmentImport.read(url); expect(false, name + " is rejected") }
            catch {
                errors.append(["file": name, "error": error.localizedDescription, "type": String(reflecting: type(of: error))])
                expect(error.localizedDescription.contains(reason), name + " preserves the expected rejection reason")
            }
        }

        try await rejected("eleven-scans.pdf", pages: Array(repeating: nil, count: 11), ocr: .failure, reason: "10")
        expect(LocalFileRecognition.probe.calls == 0, "Known excess scan pages are rejected before any OCR dependency is called")
        try await rejected("fifty-one-pages.pdf", pages: Array(repeating: nil, count: 51), ocr: .failure, reason: "50")
        expect(LocalFileRecognition.probe.calls == 0, "Overall PDF page count is checked before OCR")

        let ten = folder.appendingPathComponent("ten-scans.pdf")
        try pdf(ten, pages: Array(repeating: nil, count: 10)); LocalFileRecognition.probe.reset(.text)
        let tenResult = try await ComposerAttachmentImport.read(ten)
        expect(tenResult.kind == .pdf && LocalFileRecognition.probe.calls == 10, "Exactly ten scan pages still run all ten OCR calls")
        expect(tenResult.text.contains("scanned-page-1") && tenResult.text.hasSuffix("scanned-page-10"), "Scan results retain the first and last pages")

        let mixed = folder.appendingPathComponent("mixed-twelve-pages.pdf")
        try pdf(mixed, pages: ["native-start"] + Array(repeating: nil, count: 10) + ["native-end"])
        LocalFileRecognition.probe.reset(.text)
        let mixedResult = try await ComposerAttachmentImport.read(mixed)
        expect(LocalFileRecognition.probe.calls == 10, "The scan limit counts scan pages rather than total pages")
        let order = ["native-start", "scanned-page-1", "scanned-page-10", "native-end"].compactMap { mixedResult.text.range(of: $0)?.lowerBound }
        expect(order.count == 4 && order == order.sorted(), "Mixed native and recognized text keeps original page order")

        try await rejected("allowed-ocr-failure.pdf", pages: [nil, nil], ocr: .failure, reason: "Controlled OCR failure")
        expect(LocalFileRecognition.probe.calls == 1, "A real failure within the scan budget still stops recognition")
        try await rejected("blank-two-pages.pdf", pages: [nil, nil], ocr: .empty, reason: "PDF 未提取")
        expect(LocalFileRecognition.probe.calls == 2, "Empty recognized pages are not invented as text")

        let native = folder.appendingPathComponent("native-only.pdf")
        try pdf(native, pages: ["native-one", "native-two"]); LocalFileRecognition.probe.reset(.failure)
        let nativeResult = try await ComposerAttachmentImport.read(native)
        expect(nativeResult.text.contains("native-one") && nativeResult.text.contains("native-two"), "Native PDF text remains readable when OCR is unavailable")
        expect(LocalFileRecognition.probe.calls == 0, "Native-only PDF never enters the OCR path")

        try await rejected("eleven-scans-after-native.pdf", pages: ["native-start"] + Array(repeating: nil, count: 11), ocr: .failure, reason: "10")
        expect(LocalFileRecognition.probe.calls == 0, "Mixed over-limit PDF is rejected before recognizing its first scan")

        let hugeText = Array(repeating: String(repeating: "x", count: 120), count: 101).joined(separator: "\n")
        let hugeURL = folder.appendingPathComponent("large-native.pdf")
        try pdf(hugeURL, pages: [hugeText, nil])
        expect((PDFDocument(url: hugeURL)?.page(at: 0)?.string?.count ?? 0) > 12000, "Large native fixture actually contains over 12000 extractable characters")
        LocalFileRecognition.probe.reset(.failure)
        do { _ = try await ComposerAttachmentImport.read(hugeURL); expect(false, "Known native text overflow is rejected") }
        catch { expect(error.localizedDescription.contains("12000"), "Known native text overflow is rejected") }
        expect(LocalFileRecognition.probe.calls == 0, "Known native text overflow is rejected before OCR")
        try await rejected("large-recognized.pdf", pages: [nil], ocr: .oversized, reason: "12000")
        expect(LocalFileRecognition.probe.calls == 1, "The final text limit still checks actual OCR output")

        let report: [String: Any] = ["checks": checks, "failures": failures, "rejections": errors,
            "scope": "Actual importer/file IO/PDFKit; only OCR replaced with a controlled local probe"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
