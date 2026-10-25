import Foundation
import WeChatSkillCore
#if os(macOS)
import Vision
import ImageIO
import CryptoKit

/// Original reference JPEGs are read only. No screenshot pixels, raw OCR body,
/// contact names, account values or query text are written to the report.
@main struct ReferenceUIProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw SkillError.invalidTask }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let references: [(String,ReferencePageKind)] = [
            ("5b88b9e5f78f75ad6913b5edd2346194.jpg",.searchResults),
            ("0f5de1eeac1e6be116cbe1115ee2bded.jpg",.chat),
            ("a745b8922bec23f925db8ec0d2c05435.jpg",.contactProfile),
            ("d10de7f59a26b31e00b1e848acf53009.jpg",.personalTimeline),
            ("18a0829e405b1a2300a081486a78564a.jpg",.momentDetail),
            ("2844b63dbe6f7ca7a0d91b91cdc029c0.jpg",.chats),
            ("de13cce94eeaa61ad00b09ee96b35a69.jpg",.discover)
        ]
        var reports: [[String:Any]] = []
        for (index, reference) in references.enumerated() {
            let data = try Data(contentsOf: directory.appendingPathComponent(reference.0))
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw SkillError.invalidObservation }
            let ocr = VNRecognizeTextRequest(); ocr.recognitionLevel = .accurate
            ocr.recognitionLanguages = ["en-US","zh-Hans"]; ocr.usesLanguageCorrection = false
            let rectangles = VNDetectRectanglesRequest(); rectangles.maximumObservations = 50
            rectangles.minimumSize = 0.02; rectangles.minimumConfidence = 0.5
            rectangles.minimumAspectRatio = 0.2; rectangles.maximumAspectRatio = 1
            let contours = VNDetectContoursRequest(); contours.detectsDarkOnLight = false; contours.maximumImageDimension = 1024
            try VNImageRequestHandler(cgImage: image,options: [:]).perform([ocr,rectangles,contours])
            func rect(_ value: CGRect) -> UnitRect? {
                guard value.minX >= 0, value.minY >= 0, value.maxX <= 1, value.maxY <= 1,
                      value.width > 0, value.height > 0 else { return nil }
                return .init(x: value.minX, y: 1-value.maxY, width: value.width, height: value.height)
            }
            let texts = (ocr.results ?? []).enumerated().compactMap { i, observation -> ReferenceText? in
                guard let candidate = observation.topCandidates(1).first, let box = rect(observation.boundingBox) else { return nil }
                return .init(id:"text-\(i)",text:candidate.string,rect:box,confidence:candidate.confidence,source:.ocr)
            }
            var shapes: [ReferenceShape] = (rectangles.results ?? []).enumerated().compactMap { i, observation in
                guard let box = rect(observation.boundingBox) else { return nil }
                return .init(id:"rectangle-\(i)",kind:.rectangle,rect:box,source:.localPixels)
            }
            var number = 0
            func visit(_ contour: VNContour) {
                if let box = rect(contour.normalizedPath.boundingBox), box.width >= 0.005, box.height >= 0.004 {
                    shapes.append(.init(id:"contour-\(number)",kind:.contour,rect:box,source:.localPixels)); number += 1
                }
                for child in contour.childContours { visit(child) }
            }
            for contour in contours.results?.first?.topLevelContours ?? [] { visit(contour) }
            let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            let frame = ReferenceUIFrame(origin:.referenceImage,width:image.width,height:image.height,imageSHA256:hash,texts:texts,shapes:shapes)
            let evidence = try ReferenceUIAnalyzer.analyze(frame)
            let anchors = evidence.anchors.map { anchor -> [String:Any] in
                ["role":anchor.role,"source_ids":anchor.sourceIDs,
                 "rect":[anchor.rect.x,anchor.rect.y,anchor.rect.width,anchor.rect.height]]
            }
            reports.append(["image":index+1,"file":reference.0,"sha256":hash,"width":image.width,"height":image.height,
                "expected":reference.1.rawValue,"detected":evidence.page.rawValue,"matched":evidence.page == reference.1,
                "anchors":anchors,"gaps":evidence.gaps,"candidate_count":evidence.contactCandidates.count,
                "account_field_observed":evidence.accountReadback != nil,"query_observed":evidence.queryReadback != nil])
        }
        let count = reports.filter { $0["matched"] as? Bool == true }.count
        let result: [String:Any] = ["origin":"referenceImage","source":"user_provided_original_jpegs",
            "processing":"local_apple_vision_no_language_correction","images_processed":reports.count,
            "matched_pages":count,"all_expected_pages_matched":count == reports.count,
            "live_device_acceptance":false,"device_actions":false,"raw_private_content_persisted":false,"images":reports]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
    }
}
#else
@main struct ReferenceUIProbe { static func main() throws { throw SkillError.invalidTask } }
#endif
