import Foundation

private final class SpeakerRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct SpeakerClient {
    let settings: SpeakerSettings
    let key: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = Self.load
    func request(audio: Data) throws -> URLRequest {
        let url = try settings.validate()
        guard SpeakerSettings.validKey(key), !audio.isEmpty, audio.count <= SpeakerDocument.maxFileBytes else { throw AgentError.message("请保存独立音频服务 Key；所选录音须非空且不超过 25 MB，不会自动拆分上传") }
        let boundary = "PhoneAgent-" + UUID().uuidString
        var body = Data()
        for (name, value) in [("model", settings.model), ("response_format", "diarized_json"), ("chunking_strategy", "auto")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)); body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept"); request.httpBody = body
        return request
    }
    func analyze(audio: Data, recordingID: UUID, duration: Double) async throws -> SpeakerDocument {
        try Task.checkCancellation()
        guard duration.isFinite, (0...600).contains(duration), duration > 0 else { throw AgentError.message("所选录音时长无效") }
        let request = try request(audio: audio); let hash = SpeakerDocument.digest(audio)
        let (data, response) = try await transport(request); try Task.checkCancellation()
        guard response.url == request.url else { throw AgentError.message("音频响应来自不匹配的接口，已丢弃") }
        guard (200...299).contains(response.statusCode) else { throw Self.httpError(response.statusCode) }
        return try SpeakerDocument.decode(data, recordingID: recordingID, audioSHA256: hash, duration: duration, settings: settings, date: Date())
    }
    static func httpError(_ code: Int) -> AgentError {
        if code == 400 { return .message("音频服务 HTTP 400，请核对模型是否支持 diarized_json 及音频接口；未自动重试") }
        if code == 401 || code == 403 { return .message("音频服务 HTTP \(code)，请核对独立 Key 和权限") }
        if code == 429 { return .message("音频服务 HTTP 429，请核对额度；未自动重试") }
        return .message("音频服务 HTTP \(code)，未保存分段结果")
    }
    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: SpeakerRedirectPolicy(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.message("音频服务没有返回 HTTP 响应") }
            guard (200...299).contains(http.statusCode) else { throw httpError(http.statusCode) }
            guard http.expectedContentLength <= 1_000_000 else { throw AgentError.message("音频服务响应超过 1 MB") }
            var data = Data()
            for try await byte in bytes { if data.count % 4096 == 0 { try Task.checkCancellation() }; guard data.count < 1_000_000 else { throw AgentError.message("音频服务响应超过 1 MB") }; data.append(byte) }
            try Task.checkCancellation(); return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let e as URLError { if e.code == .cancelled { throw CancellationError() }; throw AgentError.message(e.code == .timedOut ? "音频服务超时，未自动重试" : "无法连接音频服务，请核对网络") }
    }
}
