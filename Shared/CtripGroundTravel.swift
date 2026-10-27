import Foundation

/// A display mode only; this never grants permission to purchase or make a booking.
enum CtripGroundTravelMode: String, Codable, Sendable {
    case train, bus
}

struct CtripGroundTravelOffer: Identifiable, Equatable, Sendable {
    let id: String
    let mode: CtripGroundTravelMode
    let number: String
    let departureStation: String
    let arrivalStation: String
    let departureDate: String
    let departureTime: String
    let arrivalDate: String
    let arrivalTime: String
    let seat: String
    let price: String
    let availability: String
    /// A narrowly bound provider link. Nil means only the general search action is available.
    let verifiedURL: URL?
}

/// Parses fields from one provider response. Each displayed fact comes from that
/// response; missing or ambiguous values remain empty rather than using the request.
enum CtripGroundTravelParser {
    private static let aliases: [String: [String]] = [
        "number": ["车次", "车次号", "列车车次", "列车号", "班次", "班次号"],
        "from": ["出发站", "出发车站", "发车站", "始发站", "起点站"],
        "to": ["到达站", "到站", "抵达站", "终点站", "目的站"],
        "date": ["出发日期", "乘车日期", "发车日期", "发车日", "日期"],
        "depart": ["出发时间", "发车时间", "开车时间", "发车时刻", "开车时刻"],
        "arrivalDate": ["到达日期", "抵达日期"],
        "arrive": ["到达时间", "到站时间", "抵达时间", "到达时刻"],
        "seat": ["席别", "座席", "座位类型", "座席类型", "座位", "席位"],
        "price": ["票价", "价格", "参考价格", "参考票价", "报价"],
        "availability": ["余票", "剩余票数", "剩余座位", "剩余席位", "库存", "余座"],
        "link": ["携程链接", "携程预订链接", "预订链接", "详情链接", "购票链接", "链接"]
    ]
    private static let labelToField: [String: String] = {
        var result: [String: String] = [:]
        for (field, names) in aliases { for name in names { result[name] = field } }
        return result
    }()

    static func offers(text: String, mode: CtripGroundTravelMode) -> [CtripGroundTravelOffer] {
        guard !text.isEmpty, text.utf8.count <= 128_000 else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var candidates = tableRows(lines)
        if candidates.isEmpty { candidates = blocks(lines, mode: mode) }
        if candidates.isEmpty, mode == .train { candidates = compactTrainRows(lines) }
        return candidates.enumerated().compactMap { index, fields in
            let number = clean(fields["number"] ?? "")
            let from = clean(fields["from"] ?? "")
            let to = clean(fields["to"] ?? "")
            let date = sourceDate(fields["date"] ?? "").isEmpty ? sourceDate(fields["depart"] ?? "") : sourceDate(fields["date"] ?? "")
            let departure = clock(fields["depart"] ?? "")
            // Only create a card for one identifiable departure, not a heading
            // or a generic station/route. Values are never taken from the query.
            guard !from.isEmpty, !to.isEmpty, !["无", "暂无"].contains(from), !["无", "暂无"].contains(to),
                  from != to, !date.isEmpty, !departure.isEmpty else { return nil }
            if mode == .train {
                guard number.range(of: #"^[A-Za-z]{0,2}\d{1,6}(?:/\d{1,6})?$"#, options: .regularExpression) != nil else { return nil }
            } else if number.count > 40 { return nil }
            let normalizedNumber = number.uppercased()
            return CtripGroundTravelOffer(id: mode.rawValue + "-" + String(index), mode: mode,
                number: normalizedNumber, departureStation: from, arrivalStation: to,
                departureDate: date, departureTime: departure,
                arrivalDate: sourceDate(fields["arrivalDate"] ?? "").isEmpty ?
                    (sourceDate(fields["arrive"] ?? "").isEmpty && fields["arrivalDate"] == "次日" ? "次日" : sourceDate(fields["arrive"] ?? "")) : sourceDate(fields["arrivalDate"] ?? ""),
                arrivalTime: clock(fields["arrive"] ?? ""),
                seat: clean(fields["seat"] ?? ""), price: clean(fields["price"] ?? ""),
                availability: clean(fields["availability"] ?? ""),
                // A matching host and query parameters do not establish that a
                // provider URL opens a read-only detail for this specific trip.
                // Until a supported route is verified, use the general search.
                verifiedURL: nil)
        }
    }

    private static func clean(_ source: String) -> String {
        let value = source.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 200, !value.contains("\n"),
              value.range(of: #"^(?:未知|未提供|未返回|待查|待核实|—|-)$"#, options: .regularExpression) == nil else { return "" }
        return value
    }
    private static func sourceDate(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!\d)20\d{2}[-年/]\d{1,2}[-月/]\d{1,2}日?(?!\d)"#) else { return "" }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard matches.count == 1, let match = Range(matches[0].range, in: source) else { return "" }
        let raw = String(source[match]).replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-").replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: "/", with: "-")
        let pieces = raw.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, (1...12).contains(pieces[1]), (1...31).contains(pieces[2]) else { return "" }
        var c = DateComponents(); c.calendar = Calendar(identifier: .gregorian); c.year = pieces[0]; c.month = pieces[1]; c.day = pieces[2]
        guard let date = c.date, c.calendar?.component(.month, from: date) == pieces[1], c.calendar?.component(.day, from: date) == pieces[2] else { return "" }
        return String(format: "%04d-%02d-%02d", pieces[0], pieces[1], pieces[2])
    }
    private static func clock(_ source: String) -> String {
        guard let match = source.range(of: #"(?<!\d)(?:[01]?\d|2[0-3]):[0-5]\d(?!\d)"#, options: .regularExpression) else { return "" }
        let pieces = source[match].split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]) else { return "" }
        return String(format: "%02d:%02d", hour, minute)
    }
    private static func tableRows(_ lines: [String]) -> [[String: String]] {
        var rows: [[String: String]] = []
        var headers: [String]? = nil
        for line in lines where line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { clean(String($0)) }
            if cells.contains(where: { labelToField[$0] == "from" }), cells.contains(where: { labelToField[$0] == "to" }) {
                headers = cells.map { labelToField[$0] ?? "" }; continue
            }
            guard let headers, headers.count == cells.count, !cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else { continue }
            var fields: [String: String] = [:]
            for (key, value) in zip(headers, cells) where !key.isEmpty && !value.isEmpty {
                if fields[key] != nil && fields[key] != value { fields[key] = "" } else { fields[key] = value }
            }
            rows.append(fields)
        }
        return rows
    }
    private static func blocks(_ lines: [String], mode: CtripGroundTravelMode) -> [[String: String]] {
        var result: [[String: String]] = [], fields: [String: String] = [:]
        func flush() { if !fields.isEmpty { result.append(fields); fields = [:] } }
        for raw in lines {
            let line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") { flush() }
            let unmarked = line.replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.、])\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            // A train number in a heading is a source fact for that block only.
            if mode == .train, line.hasPrefix("#"),
               let range = unmarked.range(of: #"(?<![A-Za-z0-9])[A-Za-z]{1,2}\d{1,6}(?![A-Za-z0-9])"#, options: .regularExpression) {
                fields["number"] = String(unmarked[range])
            }
            guard let colon = unmarked.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let name = String(unmarked[..<colon]).trimmingCharacters(in: .whitespaces)
            guard let key = labelToField[name] else { continue }
            let value = String(unmarked[unmarked.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "number", fields["number"] != nil, fields["number"] != value { flush() }
            if let previous = fields[key], previous != value { fields[key] = "" } else { fields[key] = value }
        }
        flush()
        return result
    }

    /// The provider may group compact rows under a station heading. Inherit
    /// only the explicitly stated result date and destination from that same
    /// official response, never the user's requested station or a timetable.
    private static func compactTrainRows(_ lines: [String]) -> [[String: String]] {
        var official = false, date = "", destination = "", origin = ""
        var result: [[String: String]] = []
        func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
        func stationKey(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"站$"#, with: "", options: .regularExpression)
        }
        let clock = #"(?:[01]?\d|2[0-3]):[0-5]\d"#
        let timing = "(" + clock + #")出发\s*→\s*((?:次日|翌日)?)"# + "(" + clock + #")到达"#
        for raw in lines {
            let line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("来源：") || line.hasPrefix("来源:") {
                official = line.contains("携程官方查询")
                date = ""; destination = ""; origin = ""
                continue
            }
            // Public schedules and explanatory sections cannot inherit the
            // preceding live-result scope, even when they mention a train.
            if line.contains("公开列车时刻表") || line.contains("公开时刻表") || line.contains("网络参考") {
                official = false; origin = ""
                continue
            }
            guard official else { continue }
            if line.contains("以下车次信息均来自携程火车票实时查询结果") {
                date = sourceDate(line)
                destination = capture(#"到达站均为([^，,。；;（）()]{1,40}站)"#, in: line) ?? ""
                continue
            }
            if line.hasPrefix("#") {
                origin = capture(#"^#{1,6}\s+([^，,。；;（）()]{1,40}站)出发车次(?:[（(][^）)]*[）)])?\s*$"#, in: line) ?? ""
                continue
            }
            guard !date.isEmpty, !origin.isEmpty, !destination.isEmpty,
                  let number = capture(#"^[-*•]\s*([A-Za-z]{1,2}\d{1,6})\s*[:：]"#, in: line),
                  let departure = capture(timing, in: line),
                  let arrival = capture(timing, in: line, group: 3) else { continue }
            if let codes = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Za-z]{1,2}\d{1,6}(?![A-Za-z0-9])"#),
               codes.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) != 1 { continue }
            // If the row repeats a route, it must agree with the explicit
            // station scope; conflicting rows stay available in the raw text.
            if let from = capture(#"[，,]\s*([^，,→。；;]{1,40})→([^，,→。；;]{1,40})(?:[，,。；;]|$)"#, in: line),
               let to = capture(#"[，,]\s*([^，,→。；;]{1,40})→([^，,→。；;]{1,40})(?:[，,。；;]|$)"#, in: line, group: 2),
               (stationKey(from) != stationKey(origin) || stationKey(to) != stationKey(destination)) { continue }
            var fields = ["number": number, "from": origin, "to": destination,
                          "date": date, "depart": departure, "arrive": arrival]
            // A later clock alone proves no calendar arrival date.
            if let relative = capture(timing, in: line, group: 2), !relative.isEmpty {
                fields["arrive"] = relative + arrival
                fields["arrivalDate"] = "次日"
            }
            // Only treat a complete, single fare as a price. Preserve known
            // qualifiers; an unknown suffix or range remains unparsed.
            if let regex = try? NSRegularExpression(pattern: #"(商务座|特等座|一等座|二等座|硬座|软座|硬卧|软卧)\s*([¥￥]?\s*\d+(?:\.\d{1,2})?元(?:\s*(?:起|以上|左右|上下))?(?:\s*(?:/人|每人))?)(?=\s*(?:[，,。；;]|$))"#) {
                let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                if matches.count == 1,
                   let seat = Range(matches[0].range(at: 1), in: line), let price = Range(matches[0].range(at: 2), in: line) {
                    fields["seat"] = String(line[seat]); fields["price"] = String(line[price])
                }
            }
            if let availability = capture(#"余票([^，,。；;]{1,60})"#, in: line) {
                let waitlist = capture(#"[，,]\s*(支持候补|不支持候补|暂不支持候补|无法候补)(?:[，,。；;]|$)"#, in: line)
                fields["availability"] = availability + (waitlist.map { "，" + $0 } ?? "")
            }
            result.append(fields)
        }
        return result
    }
}
