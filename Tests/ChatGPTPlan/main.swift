import Foundation
import CryptoKit
import Security

@main struct ChatGPTPlanChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
        func rejected(_ label: String, _ action: () throws -> Void) { do { try action(); preconditionFailure(label) } catch { checks += 1 } }
        let attempt = try ChatGPTPlanProtocol.Attempt(port: 1455)
        let second = try ChatGPTPlanProtocol.Attempt(port: 1455)
        expect(attempt.state != second.state && attempt.nonce != second.nonce && attempt.verifier != second.verifier,
               "Each OAuth attempt gets independent unpredictable binding and PKCE values")
        let url = try attempt.authorizationURL(hostID: "urn:uuid:" + UUID().uuidString)
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        expect(url.host == "auth.openai.com" && url.path == "/api/accounts/authorize" && params["client_id"] == "dynamic_agent_client" && params["agent_name_hint"] == "Sela", "Initial registration uses the documented public client entrypoint")
        expect(params["code_challenge"] == ChatGPTPlanProtocol.base64url(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))) && params["redirect_uri"] == "http://127.0.0.1:1455/auth/callback", "OAuth binds the exact IPv4 loopback redirect and S256 challenge")
        expect(params["scope"]!.contains("chatgpt.tokens.use.direct") && params["resource"] == "https://api.openai.com/v1", "Plan usage is requested as an explicit permission")
        rejected("Personal data is not a valid host ID") { _ = try attempt.authorizationURL(hostID: "person@example.com") }
        func callback(_ a: ChatGPTPlanProtocol.Attempt, changes: [String: String] = [:], omit: Set<String> = [], extra: String = "", host: String = "127.0.0.1:1455", method: String = "GET", path: String = "/auth/callback") -> Data {
            var values = ["code": "synthetic-code", "state": a.state, "client_id": "oaiapp_fixture"]
            values.merge(changes) { _, new in new }; for key in omit { values.removeValue(forKey: key) }
            var parts = URLComponents(); parts.queryItems = values.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
            return Data("\(method) \(path)?\(parts.percentEncodedQuery!)\(extra) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
        }
        let received = try ChatGPTPlanProtocol.callback(callback(attempt), attempt: attempt)
        expect(received.clientID == "oaiapp_fixture" && received.code == "synthetic-code", "New registration retains the returned client identity")
        for (label, bytes) in [("state mismatch", callback(attempt, changes: ["state": "foreign"])),
            ("duplicate binding", callback(attempt, extra: "&state=foreign")), ("foreign host", callback(attempt, host: "example.com")),
            ("path substitution", callback(attempt, path: "/callback")), ("encoded path substitution", callback(attempt, path: "/auth/%63allback")),
            ("POST callback", callback(attempt, method: "POST")), ("missing issued client", callback(attempt, omit: ["client_id"])),
            ("registration placeholder", callback(attempt, changes: ["client_id": "dynamic_agent_client"]))] {
            rejected(label) { _ = try ChatGPTPlanProtocol.callback(bytes, attempt: attempt) }
        }
        let returning = try ChatGPTPlanProtocol.Attempt(port: 1455, clientID: "oaiapp_existing")
        let returningURL = try returning.authorizationURL(hostID: "urn:uuid:" + UUID().uuidString)
        expect(!returningURL.absoluteString.contains("agent_name_hint") && !returningURL.absoluteString.contains("id_token_hint"), "Returning registration is reused without exposing retained tokens in URLs")
        let returningCallback = try ChatGPTPlanProtocol.callback(callback(returning, omit: ["client_id"]), attempt: returning)
        expect(returningCallback.clientID == "oaiapp_existing", "Returning callback may omit client ID but cannot switch it")
        rejected("Returning callback cannot replace the registration") { _ = try ChatGPTPlanProtocol.callback(callback(returning), attempt: returning) }
        do { _ = try ChatGPTPlanProtocol.callback(callback(attempt, changes: ["error": "access_denied"], omit: ["code"]), attempt: attempt); preconditionFailure("OAuth denial accepted") }
        catch ChatGPTPlanError.denied { checks += 1 }
        rejected("Oversized callback") { _ = try ChatGPTPlanProtocol.callback(Data(repeating: 65, count: 16385), attempt: attempt) }

        // Sign a fixture with an actual ephemeral RSA key; use the production
        // DER/JWKS verifier without replacing signature or identity checks.
        let privateKey = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var position = 0
        func field(_ tag: UInt8) -> Data {
            precondition(publicDER[position] == tag); position += 1
            var length = Int(publicDER[position]); position += 1
            if length >= 128 { let count = length & 127; length = 0; for _ in 0..<count { length = length * 256 + Int(publicDER[position]); position += 1 } }
            let value = publicDER.subdata(in: position..<(position + length)); position += length; return value
        }
        precondition(publicDER[position] == 0x30); position += 1
        let size = publicDER[position]; position += 1; if size >= 128 { position += Int(size & 127) }
        let modulus = field(2).drop(while: { $0 == 0 }), exponent = field(2)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture", "alg": "RS256", "use": "sig", "n": ChatGPTPlanProtocol.base64url(Data(modulus)), "e": ChatGPTPlanProtocol.base64url(exponent)]]])
        let now = Date(), client = "oaiapp_fixture"
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "fixture-subject", "aud": client, "exp": now.timeIntervalSince1970 + 3600, "nonce": attempt.nonce, "email": "fixture@example.invalid"]
        func jwt(_ changes: [String: Any] = [:], algorithm: String = "RS256", kid: String = "fixture") throws -> String {
            var payload = claims; payload.merge(changes) { _, new in new }
            let head = ChatGPTPlanProtocol.base64url(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": kid]))
            let body = ChatGPTPlanProtocol.base64url(try JSONSerialization.data(withJSONObject: payload))
            let message = head + "." + body
            let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)! as Data
            return message + "." + ChatGPTPlanProtocol.base64url(signature)
        }
        let valid = try jwt()
        let identity = try ChatGPTPlanProtocol.validateIDToken(valid, jwks: jwks, clientID: client, nonce: attempt.nonce, now: now)
        expect(identity.subject == "fixture-subject" && identity.email == "fixture@example.invalid", "Actual JWKS signature and bound identity validate")
        for (label, value) in [("wrong issuer", try jwt(["iss": "https://example.com"])), ("wrong audience", try jwt(["aud": "other-client"])),
            ("expired identity", try jwt(["exp": now.timeIntervalSince1970 - 1])), ("nonce mismatch", try jwt(["nonce": "foreign"])),
            ("unsigned algorithm", try jwt(algorithm: "none")), ("unknown key", try jwt(kid: "unknown")),
            ("multi-audience without bound azp", try jwt(["aud": [client, "other"]]))] {
            rejected(label) { _ = try ChatGPTPlanProtocol.validateIDToken(value, jwks: jwks, clientID: client, nonce: attempt.nonce, now: now) }
        }
        let tampered = String(valid.dropLast(16)) + "AAAAAAAAAAAAAAAA"
        rejected("Forged signature") { _ = try ChatGPTPlanProtocol.validateIDToken(tampered, jwks: jwks, clientID: client, nonce: attempt.nonce, now: now) }
        var profile = ChatGPTPlanProfile(id: UUID(), clientID: client, issuer: "https://auth.openai.com", subject: "fixture", accessToken: "synthetic-unused", scopes: ["openid"])
        expect(!profile.sharing, "Identity sign-in alone does not authorize plan inference")
        profile.scopes += ["resource.invoke", "chatgpt.tokens.use.direct"]
        expect(profile.sharing, "Verified identity and explicitly granted plan scopes enable the connection")
        let binding = profile.authorizationBinding!
        expect(binding != profile.accessToken && !binding.contains("synthetic-unused"), "Readiness binding is not the transport bearer")
        var rotated = profile
        rotated.accessToken = "synthetic-rotated"; rotated.refreshToken = "synthetic-refresh-rotated"
        rotated.idToken = "synthetic-id-rotated"; rotated.expiresAt = Date().addingTimeInterval(3600)
        expect(rotated.authorizationBinding == binding, "Same-account token refresh keeps pending work bound")
        var reauthorized = profile; reauthorized.authorizationID = UUID()
        expect(reauthorized.authorizationBinding != binding, "Signing in again starts a new grant even for the same account")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        legacy.removeValue(forKey: "authorizationID")
        let restoredLegacy = try JSONDecoder().decode(ChatGPTPlanProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(restoredLegacy.authorizationID == nil && restoredLegacy.authorizationBinding == binding, "Existing saved profiles remain readable without an epoch migration")
        rotated.scopes = Array(rotated.scopes.reversed()) + ["resource.invoke"]
        expect(rotated.authorizationBinding == binding, "Scope order and duplicates do not invent a new authorization")
        var changed = profile; changed.id = UUID()
        expect(changed.authorizationBinding != binding, "A different saved account invalidates the binding")
        changed = profile; changed.clientID = "another-client"
        expect(changed.authorizationBinding != binding, "A different workspace registration invalidates the binding")
        changed = profile; changed.subject = "another-subject"
        expect(changed.authorizationBinding != binding, "A different verified subject invalidates the binding")
        changed = profile; changed.scopes.append("another-granted-scope")
        expect(changed.authorizationBinding != binding, "Changed permissions invalidate the binding")
        changed = profile; changed.scopes.removeAll { $0 == "chatgpt.tokens.use.direct" }
        expect(changed.authorizationBinding == nil, "Revoked plan usage cannot retain a readiness binding")
        changed = profile; changed.accessToken = nil
        expect(changed.authorizationBinding == nil, "Cleared credentials cannot retain a readiness binding")
        changed = profile; changed.issuer = "https://example.invalid"
        expect(changed.authorizationBinding == nil, "A foreign issuer has no readiness authority")

        // Exercise the actual app readiness property and endpoint policy. The
        // credential boundary alone is synthetic; no Keychain or network use.
        var readiness = ModelReadinessProbe(settings: AgentSettings())
        expect(!readiness.modelReady, "An API connection without a credential stays unready")
        SettingsStore.fixtureCredential = "synthetic-readiness-only"
        expect(readiness.modelReady, "The existing API-key connection remains ready")
        readiness.settings.modelAuthentication = "chatgpt_plan"
        readiness.settings.endpoint = ChatGPTPlanProtocol.endpoint
        expect(readiness.modelReady, "The actual app accepts an authorized official ChatGPT Responses connection")
        SettingsStore.fixtureCredential = ""
        expect(!readiness.modelReady, "Choosing ChatGPT alone does not authorize requests")
        SettingsStore.fixtureCredential = "synthetic-readiness-only"
        for endpoint in ["https://example.com/v1/responses", "http://api.openai.com/v1/responses", "https://api.openai.com/v1/responses?foreign=1", "https://api.openai.com:8443/v1/responses", "https://api.openai.com/v1/chat/completions"] {
            readiness.settings.endpoint = endpoint
            expect(!readiness.modelReady, "Plan readiness rejects a substituted endpoint")
        }
        readiness.settings.endpoint = ChatGPTPlanProtocol.endpoint
        readiness.settings.model = "  "
        expect(!readiness.modelReady, "Plan readiness still requires a selected model")
        readiness.settings.model = "gpt-6.1-sol"; readiness.settings.modelAuthentication = nil
        expect(!readiness.modelReady, "An API-key connection cannot inherit the plan endpoint")

        let source = "原文 e\u{301}\n\t👨‍👩‍👧‍👦"
        let body = try ChatGPTPlanResponses.body(from: ["model": "gpt-6.1-sol", "messages": [["role": "system", "content": "Only JSON"], ["role": "user", "content": [["type": "text", "text": source], ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA==", "detail": "high"]]]]], "max_completion_tokens": 4000, "max_output_tokens": 4000, "temperature": 1, "metadata": ["private": "omit"], "stream": false, "store": true, "response_format": ["type": "json_object"]])
        expect(body["store"] as? Bool == false && body["stream"] as? Bool == true && body["max_output_tokens"] == nil && body["max_completion_tokens"] == nil && body["temperature"] == nil && body["metadata"] == nil, "Only supported plan request fields are sent; store/stream cannot inherit legacy settings")
        let inputs = body["input"] as! [[String: Any]], userInput = inputs.first { $0["role"] as? String == "user" }!, content = userInput["content"] as! [[String: Any]]
        expect(body["instructions"] as? String == "Only JSON" && content[0]["text"] as? String == source && content[1]["type"] as? String == "input_image", "Instructions, exact Unicode source and reference image survive real conversion")
        expect(inputs.first?["role"] as? String == "developer" && (inputs.first?["content"] as? String)?.contains("JSON") == true, "JSON object guidance also appears in input without altering the original user content")
        let schema = try ChatGPTPlanResponses.body(from: ["model": "gpt-6.1-sol", "messages": [["role": "user", "content": "JSON"]], "response_format": ["type": "json_schema", "json_schema": ["name": "action", "strict": true, "schema": ["type": "object"]]]])
        let format = (schema["text"] as! [String: Any])["format"] as! [String: Any]
        expect(format["name"] as? String == "action" && format["strict"] as? Bool == true && format["type"] as? String == "json_schema", "Structured action schema moves to Responses text.format")
        rejected("Unsupported inputs cannot disappear silently") { _ = try ChatGPTPlanResponses.body(from: ["model": "gpt-6.1-sol", "messages": [["role": "user", "content": [["type": "audio"]]]]]) }
        func event(_ value: [String: Any]) throws -> Data { Data(("data: " + String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! + "\n\n").utf8) }
        let action = "{\"kind\":\"finish\",\"text\":\"已完成\"}"
        let completion: [String: Any] = ["type": "response.completed", "response": ["id": "response-one", "status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": action]]]], "usage": ["output_tokens": 20, "output_tokens_details": ["reasoning_tokens": 2]]]]
        let delta = try event(["type": "response.output_text.delta", "delta": action])
        let finished = try event(completion)
        let wrapped = try JSONSerialization.jsonObject(with: ChatGPTPlanResponses.completion(from: delta + finished)) as! [String: Any]
        let choices = wrapped["choices"] as! [[String: Any]]
        expect((choices[0]["message"] as! [String: Any])["content"] as? String == action && choices[0]["finish_reason"] as? String == "stop", "Only a completed SSE response becomes an action envelope")
        let closedItem: [String: Any] = ["type": "response.output_item.done", "output_index": 0, "item": ["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": action]]]]
        let closed = try event(closedItem)
        let compactTerminal = try event(["type": "response.completed", "response": ["id": "response-one", "status": "completed", "output": []]])
        let compact = try JSONSerialization.jsonObject(with: ChatGPTPlanResponses.completion(from: delta + closed + compactTerminal)) as! [String: Any]
        expect(((compact["choices"] as! [[String: Any]])[0]["message"] as! [String: Any])["content"] as? String == action, "A compact terminal response reuses the full closed message, preserving exact action JSON")
        rejected("A closed message alone cannot execute") { _ = try ChatGPTPlanResponses.completion(from: closed) }
        rejected("An empty terminal plus deltas cannot execute") { _ = try ChatGPTPlanResponses.completion(from: delta + compactTerminal) }
        rejected("Duplicate closed output items cannot execute") { _ = try ChatGPTPlanResponses.completion(from: closed + closed + compactTerminal) }
        rejected("Deltas alone cannot execute") { _ = try ChatGPTPlanResponses.completion(from: delta) }
        rejected("Truncated terminal SSE cannot execute") { _ = try ChatGPTPlanResponses.completion(from: Data(finished.dropLast(2))) }
        rejected("Duplicate completion cannot execute") { _ = try ChatGPTPlanResponses.completion(from: finished + finished) }
        let failed = try event(["type": "response.failed", "response": ["id": "response-one", "error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "PRIVATE-SENTINEL"]]])
        do { _ = try ChatGPTPlanResponses.completion(from: delta + failed); preconditionFailure("Failed stream accepted") }
        catch { expect(!error.localizedDescription.contains("PRIVATE-SENTINEL"), "Provider errors cannot leak raw text or become an action") }
        rejected("Late failure invalidates success") { _ = try ChatGPTPlanResponses.completion(from: finished + failed) }
        let foreign = try event(["type": "response.created", "response": ["id": "foreign"]])
        rejected("Mixed response IDs") { _ = try ChatGPTPlanResponses.completion(from: foreign + finished) }
        let incomplete = try event(["type": "response.incomplete"])
        rejected("Incomplete response") { _ = try ChatGPTPlanResponses.completion(from: incomplete) }
        let unsafe = try JSONSerialization.data(withJSONObject: ["error": ["code": "PRIVATE-KEY-SENTINEL", "param": "PRIVATE-INPUT-SENTINEL", "message": "PRIVATE-BODY-SENTINEL"]])
        let safe = ChatGPTPlanResponses.safeHTTPFailure(unsafe, status: 400)
        expect(safe["code"] == "unknown" && safe["parameter"] == "unknown" && !safe.values.joined().contains("PRIVATE"), "HTTP diagnostics cannot retain provider-written secrets or request echoes")
        let known = try JSONSerialization.data(withJSONObject: ["error": ["code": "unsupported_parameter", "param": "text.format.type", "message": "json_object is not supported PRIVATE-SENTINEL"]])
        let classified = ChatGPTPlanResponses.safeHTTPFailure(known, status: 400)
        expect(classified["code"] == "unsupported_parameter" && classified["parameter"] == "text.format.type" && classified["reason"] == "unsupported_json_object" && !classified.values.joined().contains("PRIVATE"), "Known protocol diagnostics retain static identifiers only")
        let streamFailure = try event(["type": "response.failed", "response": ["error": ["type": "invalid_request_error", "param": "input", "message": "Input content must be an array PRIVATE-SENTINEL 123456 secret@example.invalid"]]])
        let shape = ChatGPTPlanResponses.safeStreamShape(streamFailure)
        expect(shape["event_types"] == "response.failed" && shape["stream_parameter"] == "input" && shape["stream_protocol_words"]?.contains("array") == true && !shape.values.joined().contains("PRIVATE") && !shape.values.joined().contains("123456") && !shape.values.joined().contains("example"), "Stream diagnostics preserve protocol shape but exclude raw text, numbers and identities")
        print("ChatGPT plan protocol checks passed (\(checks)); actual RSA/JWKS, OAuth binding, wire conversion and SSE terminal gates; no credentials or network.")
    }
}
