import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import CoreFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Bounded, phone-local reads. Importing never sends material to a model.
enum ComposerAttachmentImport {
    private static let maximumFileBytes = 5_000_000
    private static let maximumImageInputBytes = 10_000_000

    static func read(_ url: URL) async throws -> ComposerAttachment {
        let worker = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            guard url.isFileURL else { throw AttachmentIssue("请从本机文件选择器添加文件") }
            let name = url.lastPathComponent
            try validateName(name)
            let ext = url.pathExtension.lowercased()
            if ["doc", "ppt", "xls"].contains(ext) {
                throw AttachmentIssue("暂不支持旧版 .\(ext)，请另存为 .\(ext)x 后添加")
            }
            if UTType(filenameExtension: ext)?.conforms(to: .movie) == true {
                return try await videoAttachment(readData(url, maximum: 10_000_000, image: true), name: name)
            }
            let image = UTType(filenameExtension: ext)?.conforms(to: .image) == true
            let supported = ["pdf", "docx", "pptx", "xlsx", "txt", "md", "csv", "tsv", "json"]
            guard image || supported.contains(ext) else {
                throw AttachmentIssue("暂支持图片、Word（docx）、PDF、TXT、PPT（pptx）、Excel（xlsx）、MD、CSV、TSV 和 JSON")
            }
            let data = try readData(url, maximum: image ? maximumImageInputBytes : maximumFileBytes, image: image)
            if image { return try imageAttachment(data, name: name) }
            let text: String
            let kind: ComposerAttachment.Kind
            switch ext {
            case "pdf": text = try pdfText(data); kind = .pdf
            case "docx": text = try OfficeTextImport.read(data, ext: ext); kind = .word
            case "pptx": text = try OfficeTextImport.read(data, ext: ext); kind = .slides
            case "xlsx": text = try OfficeTextImport.read(data, ext: ext); kind = .spreadsheet
            default: text = try plainText(data); kind = .text
            }
            try Task.checkCancellation()
            let result = ComposerAttachment(name: name, kind: kind, byteCount: data.count, text: text, imageJPEG: nil)
            try ComposerAttachmentPolicy.validate([result])
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func readImage(_ data: Data, name: String) async throws -> ComposerAttachment {
        let worker = Task.detached(priority: .userInitiated) { try imageAttachment(data, name: name) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func readVideo(_ data: Data, name: String) async throws -> ComposerAttachment {
        let worker = Task.detached(priority: .userInitiated) { try await videoAttachment(data, name: name) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func videoAttachment(_ data: Data, name: String) async throws -> ComposerAttachment {
        #if canImport(UIKit)
        guard !data.isEmpty, data.count <= 10_000_000 else { throw AttachmentIssue("视频需不超过 10 MB，请先裁剪") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 60 else { throw AttachmentIssue("视频需为 60 秒以内，请先裁剪") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 600)
        defer { generator.cancelAllCGImageGeneration() }
        var frames: [(CGImage, Double)] = []
        for fraction in [0.0, 0.5, 0.9] {
            try Task.checkCancellation()
            let result = try await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 600))
            frames.append((result.image, result.actualTime.seconds))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let collage = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 660), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 660))
            for (index, frame) in frames.enumerated() {
                let y = CGFloat(index * 220)
                let image = UIImage(cgImage: frame.0)
                let scale = min(800 / image.size.width, 195 / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (800 - size.width) / 2, y: y, width: size.width, height: size.height))
                (String(format: "%.2f s", frame.1) as NSString).draw(at: CGPoint(x: 12, y: y + 198), withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
            }
        }
        guard let jpeg = collage.jpegData(compressionQuality: 0.6), jpeg.count <= ComposerAttachmentPolicy.maximumImageBytes else { throw AttachmentIssue("无法准备视频抽样画面") }
        let text = String(format: "用户选择的视频，总长 %.2f 秒。附图按顺序仅包含 3 张带实际时间的抽样画面，不是完整视频；未读取声音，不能推断抽样间的事件。", duration)
        let result = ComposerAttachment(name: name, kind: .video, byteCount: data.count, text: text, imageJPEG: jpeg, videoData: data)
        try ComposerAttachmentPolicy.validate([result]); return result
        #else
        throw AttachmentIssue("请在 iPhone 中添加视频")
        #endif
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 240 else { throw AttachmentIssue("附件名称需为 1–240 字，请重命名后添加") }
    }

    private static func readData(_ url: URL, maximum: Int, image: Bool) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AttachmentIssue("请选择文件，暂不支持文件夹") }
        if let size = values.fileSize, size > maximum {
            throw AttachmentIssue(image ? "图片需不超过 10 MB" : "文件需不超过 5 MB，请拆分后添加")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximum {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(1_000_000, maximum + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw AttachmentIssue("文件为空，请选择有内容的文件") }
        guard data.count <= maximum else {
            throw AttachmentIssue(image ? "图片需不超过 10 MB" : "文件需不超过 5 MB，请拆分后添加")
        }
        return data
    }

    private static func plainText(_ data: Data) throws -> String {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if let value = String(data: data, encoding: .utf8) {
            text = value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
        } else {
            text = String(data: data, encoding: gb18030)
        }
        guard let text, !text.unicodeScalars.contains(where: { scalar in
            scalar.value == 0 || (scalar.value < 32 && ![9, 10, 12, 13].contains(scalar.value))
        }) else { throw AttachmentIssue("无法读取文字编码，请另存为 UTF-8、带 BOM 的 UTF-16 或 GB18030 文本") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AttachmentIssue("文件中没有可读取的文字") }
        guard text.count <= ComposerAttachmentPolicy.maximumTextCharacters else {
            throw AttachmentIssue("文件文字超过 12000 字，请拆分后添加；没有截断内容")
        }
        return text
    }

    private static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else { throw AttachmentIssue("PDF 无法读取或已加密，请先解密后添加") }
        guard (1...50).contains(document.pageCount) else { throw AttachmentIssue("PDF 需为 1–50 页，请拆分后添加") }
        var inputs: [(page: PDFPage, text: String, requiresOCR: Bool)] = []
        var scannedPages = 0
        var minimumCharacterCount = 0
        // Check the complete scan budget before starting expensive OCR. A
        // known over-limit file must not depend on OCR availability to reject it.
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw AttachmentIssue("PDF 第 \(index + 1) 页无法读取") }
            let original = page.string ?? ""
            let requiresOCR = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if requiresOCR {
                scannedPages += 1
                guard scannedPages <= 10 else { throw AttachmentIssue("一次最多识别 10 页扫描 PDF，请拆分后添加") }
            }
            minimumCharacterCount += (requiresOCR ? 0 : original.count) + (inputs.isEmpty ? 0 : 2)
            guard minimumCharacterCount <= ComposerAttachmentPolicy.maximumTextCharacters else {
                throw AttachmentIssue("PDF 文字超过 12000 字，请拆分后添加；没有截断内容")
            }
            inputs.append((page, original, requiresOCR))
        }
        var pages: [String] = []
        var characterCount = 0
        for input in inputs {
            try Task.checkCancellation()
            let text = input.requiresOCR ? try LocalFileRecognition.scannedPage(input.page) : input.text
            characterCount += text.count + (pages.isEmpty ? 0 : 2)
            guard characterCount <= ComposerAttachmentPolicy.maximumTextCharacters else {
                throw AttachmentIssue("PDF 文字超过 12000 字，请拆分后添加；没有截断内容")
            }
            pages.append(text)
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentIssue("PDF 未提取到清晰文字，请改传相关页面的图片")
        }
        return text
    }

    private static func imageAttachment(_ data: Data, name: String) throws -> ComposerAttachment {
        try Task.checkCancellation()
        try validateName(name)
        guard !data.isEmpty, data.count <= maximumImageInputBytes else { throw AttachmentIssue("图片需为 1 字节–10 MB") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 100_000, height.doubleValue <= 100_000,
              width.doubleValue * height.doubleValue <= 200_000_000 else {
            throw AttachmentIssue("图片无效或像素过大，请另存为普通 JPG、PNG 或 HEIC 图片")
        }
        var preparedImage: CGImage?
        var jpeg: Data?
        for side in [1600, 1280] {
            try Task.checkCancellation()
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary), let opaque = opaqueImage(thumbnail) else {
                throw AttachmentIssue("无法读取图片，请另存为 JPG、PNG 或 HEIC 后添加")
            }
            for quality in [0.82, 0.68, 0.5, 0.35] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw AttachmentIssue("无法准备图片附件")
                }
                CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentIssue("图片压缩失败，请重新选择") }
                if output.length <= ComposerAttachmentPolicy.maximumImageBytes {
                    jpeg = output as Data; preparedImage = opaque; break
                }
            }
            if jpeg != nil { break }
        }
        guard let jpeg, let preparedImage else { throw AttachmentIssue("图片压缩后仍超过 600 KB，请裁剪或另存后添加") }
        try Task.checkCancellation()
        // Text recognition is supplementary: an ordinary photo without readable
        // words is still a valid visual attachment.
        let text: String
        do { text = try LocalFileRecognition.imageText(preparedImage) }
        catch is CancellationError { throw CancellationError() }
        catch { text = "" }
        try Task.checkCancellation()
        guard text.count <= ComposerAttachmentPolicy.maximumTextCharacters else {
            throw AttachmentIssue("图片识别文字超过 12000 字，请裁剪后添加；没有截断内容")
        }
        let result = ComposerAttachment(name: name, kind: .image, byteCount: data.count, text: text, imageJPEG: jpeg)
        try ComposerAttachmentPolicy.validate([result])
        return result
    }

    private static func opaqueImage(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
