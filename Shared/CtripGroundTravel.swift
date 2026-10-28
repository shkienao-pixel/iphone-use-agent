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

/// Read-only presentation evidence, including records without identifiable
/// coach terminals. This type never establishes a selectable/bookable trip.
struct CtripGroundTravelDisplayEntry: Identifiable, Equatable, Sendable {
    let id: String
    let mode: CtripGroundTravelMode
    let number: String
    let departureStation: String
    let arrivalStation: String
    let departureCity: String
    let arrivalCity: String
    let departureDate: String
    let departureTime: String
    let arrivalDate: String
    let arrivalTime: String
    let seat: String
    let price: String
    let availability: String
    let duration: String
    let serviceFee: String
    let isComplete: Bool
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
        if mode == .bus {
            guard !excludesCoachResults(text) else { return [] }
            return offers(candidates: coachDisplayFields(lines).map(\.values), mode: .bus)
        }
        // A recognized summary response must not bypass its conflict checks
        // through a looser field-block parser after a deliberate rejection.
        if mode == .train, let summaries = summaryTrainBlocks(lines) {
            return offers(candidates: summaries, mode: mode)
        }
        // A heading can produce a partial block without enough facts for a
        // card. Fall through after validation, not merely after parsing fields.
        var formats = [tableRows(lines), blocks(lines, mode: mode)]
        if mode == .train { formats.append(compactTrainRows(lines)) }
        for candidates in formats {
            let parsed = offers(candidates: candidates, mode: mode)
            if !parsed.isEmpty { return parsed }
        }
        return []
    }

    private static func offers(candidates: [[String: String]], mode: CtripGroundTravelMode) -> [CtripGroundTravelOffer] {
        let parsed: [CtripGroundTravelOffer] = candidates.enumerated().compactMap { index, fields in
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
            } else if number.count > 40 || !coachStation(from) || !coachStation(to) { return nil }
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
        guard mode == .train else { return parsed }
        func identity(_ offer: CtripGroundTravelOffer) -> String {
            [offer.number, offer.departureDate, offer.departureStation, offer.arrivalStation]
                .map { $0.replacingOccurrences(of: #"站$"#, with: "", options: .regularExpression) }.joined(separator: "|")
        }
        let groups = Dictionary(grouping: parsed, by: identity)
        let conflictingTrips = Set(groups.compactMap { key, group -> String? in
            guard let first = group.first else { return nil }
            return group.allSatisfy {
                $0.departureTime == first.departureTime && $0.arrivalTime == first.arrivalTime &&
                $0.arrivalDate == first.arrivalDate
            } ? nil : key
        })
        func seatIdentity(_ offer: CtripGroundTravelOffer) -> String { identity(offer) + "|" + offer.seat }
        let seats = Dictionary(grouping: parsed, by: seatIdentity)
        var seen = Set<String>()
        return parsed.filter { offer in
            guard !conflictingTrips.contains(identity(offer)) else { return false }
            let key = seatIdentity(offer)
            guard seen.insert(key).inserted else { return false }
            // Different seats are distinct offers on the same timetable.
            // Repeated versions of one seat must still agree on fare/inventory.
            return seats[key]?.allSatisfy {
                $0.price == offer.price && $0.availability == offer.availability
            } ?? false
        }
    }

    /// Train presentation keeps its existing direct-route/conflict safeguards.
    /// Coach presentation intentionally has a separate, weaker *display* model:
    /// partial facts stay visible without becoming complete offers.
    static func displayEntries(text: String, mode: CtripGroundTravelMode) -> [CtripGroundTravelDisplayEntry] {
        guard !text.isEmpty, text.utf8.count <= 128_000 else { return [] }
        if mode == .train {
            return offers(text: text, mode: mode).map { offer in
                CtripGroundTravelDisplayEntry(id: offer.id, mode: mode, number: offer.number,
                    departureStation: offer.departureStation, arrivalStation: offer.arrivalStation,
                    departureCity: "", arrivalCity: "", departureDate: offer.departureDate,
                    departureTime: offer.departureTime, arrivalDate: offer.arrivalDate,
                    arrivalTime: offer.arrivalTime, seat: offer.seat, price: offer.price,
                    availability: offer.availability, duration: "", serviceFee: "",
                    isComplete: true, verifiedURL: offer.verifiedURL)
            }
        }
        guard !excludesCoachResults(text) else { return [] }
        return coachDisplayFields(text.components(separatedBy: .newlines)).enumerated().map { index, record in
            let f = record.values
            // The complete-offer validator remains the authority for completeness.
            // These fields never use the query or inherit facts from another row.
            let complete = !offers(candidates: [f], mode: .bus).isEmpty
            return CtripGroundTravelDisplayEntry(id: "bus-display-" + String(index), mode: .bus,
                number: f["number"] ?? "", departureStation: f["from"] ?? "",
                arrivalStation: f["to"] ?? "", departureCity: f["fromCity"] ?? "",
                arrivalCity: f["toCity"] ?? "", departureDate: f["date"] ?? "",
                departureTime: f["depart"] ?? "", arrivalDate: f["arrivalDate"] ?? "",
                arrivalTime: f["arrive"] ?? "", seat: f["seat"] ?? "", price: f["price"] ?? "",
                availability: f["availability"] ?? "", duration: f["duration"] ?? "",
                serviceFee: f["serviceFee"] ?? "", isComplete: complete, verifiedURL: nil)
        }
    }

    private static func excludesCoachResults(_ text: String) -> Bool {
        // The source wrapper only proves which connector answered. It cannot
        // turn its stated failure, public timetable or sample into live trips.
        text.range(of: #"(?:(?:公开|历史)[^\n。]{0,12}时刻表|网络参考|模拟数据|示例数据|以下(?:仅为|为)(?:示例|演示)|未查询到|未查到|没有查询到|没有查到|未(?:获取|取得)到?[^\n。]{0,30}(?:班次|结果)|暂无(?:可用)?(?:班次|查询结果)|未返回[^\n。]{0,30}(?:班次|查询结果)|没有实际[^\n。]{0,30}(?:班次|结果))"#,
                   options: .regularExpression) != nil
    }

    private static func coachStation(_ value: String) -> Bool {
        // A city, district, an unknown marker or "具体车站以下单为准" is not a
        // terminal. Require explicit station/facility wording, conservatively.
        guard !value.isEmpty,
              value.range(of: #"(?:未知|未提供|未返回|待查|待核实|待确认|未确认|以.*为准|具体.*(?:未知|未明)|^(?:不是|并非|非|不在))"#, options: .regularExpression) == nil else { return false }
        return value.contains("站") || value.contains("客运中心") || value.contains("交通枢纽")
    }

    private struct DisplayFields {
        var values: [String: String] = [:]
        var conflicts = Set<String>()
        var hasJourneyField = false
        var explicitCoachHeading = false
        mutating func put(_ key: String, _ value: String) {
            guard !conflicts.contains(key) else { return }
            if let prior = values[key], prior != value {
                values[key] = ""; conflicts.insert(key)
            } else { values[key] = value }
        }
        mutating func reject(_ key: String) {
            values[key] = ""; conflicts.insert(key)
        }
    }

    private static let displayAliases: [String: String] = {
        var result = labelToField
        for (key, names) in [
            "from": ["出发客运站", "实际出发客运站", "始发客运站", "出发站点", "发车站点"],
            "to": ["到达客运站", "实际到达客运站", "终到客运站", "到达站点"],
            "fromCity": ["出发城市", "始发城市", "出发地", "起点城市"],
            "toCity": ["到达城市", "目的城市", "目的地", "终点城市"],
            "departureDateTime": ["发车日期时间", "出发日期时间", "发车日期和时间", "出发日期和时间", "出发日期及时间"],
            "arrivalDateTime": ["到达日期时间", "抵达日期时间", "到达日期和时间"],
            "route": ["出发/到达", "出发／到达", "起点/终点", "出发地/目的地", "路线", "线路"],
            "duration": ["历时", "耗时", "行程时长", "时长"],
            "serviceFee": ["在线服务费", "服务费", "手续费"]
        ] { for name in names { result[name] = key } }
        result["参考价格"] = "referencePrice"
        result["参考票价"] = "referencePrice"
        return result
    }()

    private static func displayValue(_ raw: String) -> String {
        let value = clean(raw).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard value.range(of: #"^(?:无|暂无|暂无数据|未提供.*|未返回.*|待核实.*|未知.*|未明确.*|不详|N/A|null)$"#,
                          options: [.regularExpression, .caseInsensitive]) == nil else { return "" }
        return value
    }

    private static func exactDisplayDate(_ value: String) -> String {
        guard value.range(of: #"^20\d{2}[-年/]\d{1,2}[-月/]\d{1,2}日?$"#, options: .regularExpression) != nil else { return "" }
        return sourceDate(value)
    }

    private static func exactDisplayClock(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "：", with: ":")
        guard normalized.range(of: #"^(?:[01]?\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return "" }
        return clock(normalized)
    }

    private static func recordDisplayField(_ key: String, raw: String, into fields: inout DisplayFields) {
        let value = displayValue(raw)
        if ["from", "to", "fromCity", "toCity", "route", "date", "depart", "departureDateTime"].contains(key) {
            fields.hasJourneyField = true
        }
        switch key {
        case "departureDateTime", "arrivalDateTime":
            let dateKey = key == "departureDateTime" ? "date" : "arrivalDate"
            let timeKey = key == "departureDateTime" ? "depart" : "arrive"
            let normalized = value.replacingOccurrences(of: "：", with: ":")
            if let regex = try? NSRegularExpression(pattern: #"^(20\d{2}[-年/]\d{1,2}[-月/]\d{1,2}日?)\s*((?:[01]?\d|2[0-3]):[0-5]\d)$"#),
               let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
               let dateRange = Range(match.range(at: 1), in: normalized), let timeRange = Range(match.range(at: 2), in: normalized) {
                fields.put(dateKey, exactDisplayDate(String(normalized[dateRange])))
                fields.put(timeKey, exactDisplayClock(String(normalized[timeRange])))
            } else { fields.reject(dateKey); fields.reject(timeKey) }
        case "date", "arrivalDate":
            fields.put(key, key == "arrivalDate" && ["次日", "翌日"].contains(value) ? "次日" : exactDisplayDate(value))
        case "depart", "arrive":
            fields.put(key, exactDisplayClock(value))
        case "route":
            let pieces = value.replacingOccurrences(of: "->", with: "→").components(separatedBy: "→")
            guard pieces.count == 2, pieces.allSatisfy({ !displayValue($0).isEmpty }) else {
                for endpoint in ["from", "to", "fromCity", "toCity"] { fields.reject(endpoint) }
                return
            }
            for (endpoint, piece) in zip(["from", "to"], pieces) {
                let place = displayValue(piece)
                fields.put(coachStation(place) ? endpoint : endpoint + "City", place)
            }
        case "from", "to":
            if value.range(of: #"(?:未知|未提供|未返回|待查|待核实|待确认|未确认|以.*为准|暂无|未明确|^(?:不是|并非|非|不在))"#, options: .regularExpression) != nil {
                fields.put(key, "")
            } else if coachStation(value) {
                fields.put(key, value)
            } else if !value.isEmpty {
                fields.put(key + "City", value)
                // Explicit station fields returning only a city cannot later
                // silently become a known station within the same record.
                fields.put(key, "")
            } else { fields.put(key, "") }
        case "fromCity", "toCity":
            fields.put(key, value)
        case "referencePrice": fields.put("price", value.isEmpty ? "" : "参考" + value)
        case "link": break // URLs never establish a supported specific-trip handoff.
        default: fields.put(key, value)
        }
    }

    private static func coachDisplayFields(_ lines: [String]) -> [DisplayFields] {
        var result: [DisplayFields] = [], fields = DisplayFields()
        var headers: [String]? = nil
        func append(_ value: DisplayFields) {
            // A fare paragraph, heading, error text or train summary alone is
            // not a coach record. Ordinal headings are not provider trip IDs.
            guard value.hasJourneyField,
                  value.values.values.contains(where: { !$0.isEmpty }),
                  (value.explicitCoachHeading || (value.values["number"] ?? "").range(of: #"^[GDCZTKYSL]\d{1,6}$"#, options: [.regularExpression, .caseInsensitive]) == nil) else { return }
            result.append(value)
        }
        func flush() { append(fields); fields = DisplayFields() }
        for raw in lines {
            let line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("|") {
                var pieces = line.components(separatedBy: "|")
                if pieces.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { pieces.removeFirst() }
                if pieces.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { pieces.removeLast() }
                let cells = pieces.map { displayValue($0) }
                let keys = cells.map { displayAliases[$0] ?? "" }
                if keys.filter({ !$0.isEmpty }).count >= 2,
                   keys.contains(where: { ["from", "to", "fromCity", "toCity", "route", "date", "depart", "departureDateTime"].contains($0) }) {
                    flush(); headers = keys; continue
                }
                if cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) { continue }
                if let headers, cells.count == headers.count {
                    flush(); var row = DisplayFields()
                    for (key, value) in zip(headers, cells) where !key.isEmpty { recordDisplayField(key, raw: value, into: &row) }
                    append(row)
                    continue
                }
                headers = nil
            } else if !line.isEmpty { headers = nil }
            let unmarked = line.replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.、])\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            let coachHeading = unmarked.range(of: #"^(?:(?:汽车|客运|大巴)班次|班次(?:[一二三四五六七八九十百零〇\d]+)|第[一二三四五六七八九十百零〇\d]+(?:个)?班次)(?:\s*[（(].*[）)])?\s*$"#, options: .regularExpression) != nil
            if line.hasPrefix("#") || coachHeading { flush() }
            if coachHeading {
                fields.explicitCoachHeading = true
                // Only an explicit, single departure clock in the heading is
                // used; a later contradictory field locks it to unknown.
                if let regex = try? NSRegularExpression(pattern: #"[（(]((?:[01]?\d|2[0-3])[:：][0-5]\d)出发[）)]"#),
                   let match = regex.firstMatch(in: unmarked, range: NSRange(unmarked.startIndex..., in: unmarked)),
                   let range = Range(match.range(at: 1), in: unmarked) {
                    recordDisplayField("depart", raw: String(unmarked[range]), into: &fields)
                }
                continue
            }
            guard let colon = unmarked.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let name = String(unmarked[..<colon]).trimmingCharacters(in: .whitespaces)
            guard let key = displayAliases[name] else { continue }
            let rawValue = String(unmarked[unmarked.index(after: colon)...])
            // An explicit new identifier starts another source row even when
            // Markdown headings are absent. Never combine A's departure with
            // B's destination to manufacture one complete trip.
            if key == "number", fields.hasJourneyField,
               let previous = fields.values[key], !previous.isEmpty,
               previous != displayValue(rawValue), !displayValue(rawValue).isEmpty {
                let coachScope = fields.explicitCoachHeading
                flush(); fields.explicitCoachHeading = coachScope
            }
            recordDisplayField(key, raw: rawValue, into: &fields)
        }
        flush()
        return result
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

    /// The official response can contain a prose fare followed by a compact
    /// provider summary. Bind one train to an explicitly dated direct-route
    /// section, then verify the summary's own date and stations against it.
    /// Transfer and alternative-station sections remain in the original text.
    private static func summaryTrainBlocks(_ lines: [String]) -> [[String: String]]? {
        var official = false, date = "", origin = "", destination = ""
        var fields: [String: String] = [:], declared: [String: String] = [:], result: [[String: String]] = []
        var invalid = false, hasSummary = false, recognized = false
        var fares: [[String: String]] = []
        func groups(_ pattern: String, _ text: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
        func stationKey(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"站$"#, with: "", options: .regularExpression)
        }
        func fieldValue(_ value: String, key: String) -> String {
            switch key {
            case "from", "to": return stationKey(clean(value))
            case "date":
                guard clean(value).range(of: #"^20\d{2}[-年/]\d{1,2}[-月/]\d{1,2}日?$"#, options: .regularExpression) != nil else { return "" }
                return sourceDate(value)
            case "depart", "arrive":
                guard clean(value).range(of: #"^(?:[01]?\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return "" }
                return clock(value)
            default: return clean(value).uppercased()
            }
        }
        func flush() {
            let consistent = declared.allSatisfy { key, value in
                !value.isEmpty && fieldValue(fields[key] ?? "", key: key) == value
            }
            if hasSummary && !invalid && consistent {
                if fares.isEmpty { result.append(fields) }
                else { result.append(contentsOf: fares.map { fields.merging($0) { _, fare in fare } }) }
            }
            fields = [:]; declared = [:]; invalid = false; hasSummary = false; fares = []
        }
        let time = #"(?:[01]?\d|2[0-3]):[0-5]\d"#
        let summary = #"^[-*•]\s*(\d{1,2})月(\d{1,2})日\s+(?:周[一二三四五六日天]\s+)?("# + time + #")\s+([^\s→]{1,40})\s*→\s*("# + time + #")\s+([^\s→]{1,40})$"#
        for raw in lines {
            let line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("来源：") || line.hasPrefix("来源:") {
                flush(); official = line.contains("携程官方查询"); date = ""; origin = ""; destination = ""
                continue
            }
            guard official else { continue }
            if line.contains("公开时刻表") || line.contains("公开列车时刻表") || line.contains("网络参考") {
                flush(); official = false; continue
            }
            if line.hasPrefix("以下为"), line.contains("查询结果") {
                flush(); date = sourceDate(line); origin = ""; destination = ""
                continue
            }
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                flush(); origin = ""; destination = ""
                if let route = groups(#"^#{1,2}\s+直达车次[（(]\s*([^→，,。；;（）()]{1,40})\s*→\s*([^→，,。；;（）()]{1,40})\s*[）)]$"#, line) {
                    origin = stationKey(route[0]); destination = stationKey(route[1])
                }
                continue
            }
            if !origin.isEmpty, !destination.isEmpty,
               line.range(of: #"^#{4,6}\s"#, options: .regularExpression) != nil { recognized = true }
            guard !date.isEmpty, !origin.isEmpty, !destination.isEmpty, origin != destination else { continue }
            if line.hasPrefix("### ") {
                flush()
                if let train = groups(#"^###\s+([A-Za-z]{1,2}\d{1,6})(?:[（(][^）)]*[）)])?\s*$"#, line),
                   !line.contains("中转"), !line.contains("转乘"), !line.contains("换乘"),
                   line.range(of: #"第[0-9一二三四五六七八九十]+段"#, options: .regularExpression) == nil,
                   let codes = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Za-z]{1,2}\d{1,6}(?![A-Za-z0-9])"#),
                   codes.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) == 1 { fields["number"] = train[0] }
                continue
            }
            guard let number = fields["number"] else { continue }
            if line.hasPrefix("#") {
                if groups(#"^#{4,6}\s*[·•]?\s*([A-Za-z]{1,2}\d{1,6})\s*$"#, line)?.first != number { invalid = true }
                continue
            }
            if line.range(of: #"第[0-9一二三四五六七八九十]+段"#, options: .regularExpression) != nil ||
                line.contains("中转") || line.contains("转乘") || line.contains("换乘") { invalid = true }
            if let label = groups(#"^[-*•]\s*([^:：]+)[:：]\s*(.*)$"#, line),
               let key = labelToField[label[0].trimmingCharacters(in: .whitespaces)],
               ["number", "from", "to", "date", "depart", "arrive"].contains(key) {
                let value = fieldValue(label[1], key: key)
                if let previous = declared[key], previous != value { invalid = true }
                declared[key] = value
            }
            if let row = groups(summary, line) {
                let parts = date.split(separator: "-").compactMap { Int($0) }
                guard !hasSummary, parts.count == 3, Int(row[0]) == parts[1], Int(row[1]) == parts[2],
                      stationKey(row[3]) == origin, stationKey(row[5]) == destination else { invalid = true; continue }
                if let departure = fields["depart"], departure != clock(row[2]) { invalid = true }
                if let arrival = fields["arrive"], arrival != clock(row[4]) { invalid = true }
                fields["from"] = row[3]; fields["to"] = row[5]; fields["date"] = date
                fields["depart"] = clock(row[2]); fields["arrive"] = clock(row[4]); hasSummary = true
            } else if let timing = groups(#"^[-*•]\s*发车/到达[:：]\s*("# + time + #")\s*→\s*("# + time + #")(?:[，,].*)?$"#, line) {
                if let departure = fields["depart"], departure != clock(timing[0]) { invalid = true }
                if let arrival = fields["arrive"], arrival != clock(timing[1]) { invalid = true }
                fields["depart"] = clock(timing[0]); fields["arrive"] = clock(timing[1])
            } else if line.range(of: #"^[-*•]\s*发车/到达[:：]"#, options: .regularExpression) != nil {
                // A known timing label in an unsupported format may contain
                // additional route facts; do not silently discard those facts.
                invalid = true
            } else if let seat = groups(#"^[-*•]\s*(商务座|特等座|一等座|二等座|硬座|软座|硬卧|软卧)[:：]"#, line)?.first {
                // Each fare stays bound to its own seat. An unparsed quote is
                // retained as unknown, so it cannot silently validate a
                // contradictory, complete quote for the same seat.
                var values = ["seat": seat, "price": "", "availability": ""]
                if let fare = groups(#"^[-*•]\s*(商务座|特等座|一等座|二等座|硬座|软座|硬卧|软卧)[:：]\s*([¥￥]\s*\d+(?:\.\d{1,2})?元?(?:\s*(?:起|以上|左右|上下))?(?:\s*(?:/人|每人))?)\s*[，,]\s*((?:余\d+张|有票|无票|售罄|候补)(?:[，,](?:支持候补|不支持候补|暂不支持候补|无法候补))?)$"#, line) {
                    values["price"] = fare[1]; values["availability"] = fare[2]
                }
                fares.append(values)
            }
        }
        flush()
        return recognized ? result : nil
    }
}
