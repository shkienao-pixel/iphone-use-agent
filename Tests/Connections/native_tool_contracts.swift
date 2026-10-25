import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

@main struct NativeToolChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    static func rejects(_ json: String) { do { _ = try SystemToolRequest.decode(json); expect(false, "Invalid request accepted: " + json) } catch { expect(true, "Rejected") } }
    static func main() throws {
        for scope in ["steps", "sleep", "workouts"] {
            let request = try SystemToolRequest.decode("{\"operation\":\"health_query\",\"query\":\"\(scope)\",\"start\":\"2026-10-23T00:00:00+08:00\",\"end\":\"2026-10-24T00:00:00+08:00\"}")
            expect(request.operation == .health_query, "Health scope rejected")
        }
        for bad in [
            "{\"operation\":\"health_query\",\"query\":\"all\"}",
            "{\"operation\":\"health_query\",\"query\":\"steps\",\"start\":\"2026-10-01T00:00:00Z\",\"end\":\"2026-11-02T00:00:00Z\"}",
            "{\"operation\":\"health_query\",\"query\":\"sleep\",\"start\":\"2026-10-01T00:00:00\",\"end\":\"2026-10-02T00:00:00Z\"}",
            "{\"operation\":\"health_query\",\"query\":\"steps\",\"start\":\"2026-10-02T00:00:00Z\",\"end\":\"2026-10-01T00:00:00Z\"}",
            "{\"operation\":\"music_search\",\"query\":\" \"}",
            "{\"operation\":\"music_play\",\"query\":\"0\",\"title\":\"Song\"}",
            "{\"operation\":\"music_play\",\"query\":\"18446744073709551616\",\"title\":\"Song\"}",
            "{\"operation\":\"music_play\",\"query\":\"123;open\",\"title\":\"Song\"}",
            "{\"operation\":\"music_play\",\"query\":\"123\"}",
            "{\"operation\":\"music_pause\",\"query\":\"any\"}",
            "{\"operation\":\"music_resume\",\"title\":\"any\"}",
            "{\"operation\":\"music_status\",\"notes\":\"any\"}",
            "{\"operation\":\"location_current\",\"start\":\"2026-10-01T00:00:00Z\"}",
            "{\"operation\":\"location_current\",\"precise\":true}"
        ] { rejects(bad) }
        let search = try SystemToolRequest.decode("{\"operation\":\"music_search\",\"query\":\"坂本龙一\"}")
        expect(!search.operation.writes, "Music search mutates data")
        let play = try SystemToolRequest.decode("{\"operation\":\"music_play\",\"query\":\"18446744073709551615\",\"title\":\"Song\"}")
        expect(play.operation.changesPlayback && !play.operation.writes, "Playback must not use create-receipt canonicalization")
        for operation in ["music_pause", "music_resume", "music_status", "location_current"] {
            _ = try SystemToolRequest.decode("{\"operation\":\"\(operation)\"}"); expect(true, "No-parameter operation")
        }
        let note = try SystemToolRequest.decode("{\"operation\":\"notes_create\",\"title\":\"Sela测试-标题\",\"content\":\"中文 😀\\n第二行\\n\",\"folder_name\":\"Sela测试-文件夹\"}")
        expect(note.operation.writes && note.content == "中文 😀\n第二行\n", "Notes is a protected write preserving exact body")
        let defaultNote = try SystemToolRequest.decode("{\"operation\":\"notes_create\",\"title\":\"test\",\"content\":\"body\"}")
        expect(defaultNote.folder_name == nil && defaultNote.operation.writes, "Unspecified folder uses explicit host configuration")
        for bad in [
            "{\"operation\":\"notes_create\",\"title\":\"test\",\"content\":\"body\",\"folder_name\":\"\"}",
            "{\"operation\":\"notes_create\",\"title\":\"test\\nextra\",\"content\":\"body\",\"folder_name\":\"test\"}",
            "{\"operation\":\"notes_create\",\"title\":\"test\",\"content\":\"body\",\"folder_name\":\"test\",\"query\":\"ignore\"}",
            "{\"operation\":\"notes_create\",\"title\":\"test\",\"content\":\"\",\"folder_name\":\"test\"}",
            "{\"operation\":\"music_status\",\"folder_name\":\"test\"}",
            "{\"operation\":\"notes_create\",\"title\":\"test\",\"content\":\"body\",\"folder_name\":\"test\",\"shortcut_url\":\"other://action\"}"
        ] { rejects(bad) }
        let date = Date(timeIntervalSince1970: 0)
        func interval(_ start: Double, _ end: Double) -> DateInterval { DateInterval(start: date.addingTimeInterval(start), end: date.addingTimeInterval(end)) }
        let window = interval(0, 10)
        expect(NativeToolData.sleepSeconds([interval(-10, 3), interval(1, 5), interval(3, 5), interval(5, 8), interval(9, 20)], within: window) == 9, "Overlapping sleep sources double-counted or window not clipped")
        expect(NativeToolData.sleepSeconds([interval(-20, -10), interval(15, 20)], within: window) == 0, "Out-of-range data counted")
        expect(NativeToolData.sleepSeconds([], within: window) == 0, "Empty interval union")
        expect(NativeToolData.approximateCoordinate(31.234567) == 31.235, "Positive location precision")
        expect(NativeToolData.approximateCoordinate(-121.987654) == -121.988, "Negative location precision")
        expect(SystemToolRequest.instructions.contains("null/empty is unknown"), "Health uncertainty instruction missing")
        print("PASS: \(checks) native tool contract, range, playback, overlapping sleep and approximate-location checks")
    }
}
