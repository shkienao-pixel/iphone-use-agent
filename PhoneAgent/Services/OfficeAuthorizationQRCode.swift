import Foundation
import Vision

enum OfficeAuthorizationQRCode {
    static func payload(_ encoded: String) async -> String? {
        guard encoded.utf8.count <= 750_000, let data = Data(base64Encoded: encoded) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
            try? VNImageRequestHandler(data: data).perform([request])
            return request.results?.first?.payloadStringValue
        }.value
    }
}
