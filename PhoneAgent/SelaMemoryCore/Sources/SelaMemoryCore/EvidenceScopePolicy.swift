import Foundation

/// A narrow admission rule for automatic learning, not a general fact
/// classifier. Explicit single-request parameters remain in that conversation
/// even if a model proposes personal scope. Owner-authored remember() is intact.
enum EvidenceScopePolicy {
    private enum Parameter { case budget, schedule, singleTask }

    static func restrictedScope(for fact: RememberedFact, sources: [MemoryMessage], conversationID: UUID) -> MemoryScope {
        guard fact.scope == .personal, let parameter = parameter(in: fact) else { return fact.scope }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var temporary = false, durable = false
        for evidence in fact.evidence {
            guard let source = byID[evidence.messageID], source.role == .user, !source.excludedFromRecall,
                  !evidence.quote.isEmpty, source.text.contains(evidence.quote) else { continue }
            // Inspect the real source clause around the quote. A shortened quote
            // such as "预算1500元" must not discard its user's "这次" qualifier.
            for clause in sourceClauses(source.text, quoted: evidence.quote) {
                guard relevant(clause, to: parameter) else { continue }
                if parameter == .budget {
                    let factValues = amounts(in: fact.text), sourceValues = amounts(in: clause)
                    if !factValues.isEmpty, !sourceValues.isEmpty, factValues.isDisjoint(with: sourceValues) { continue }
                }
                temporary = temporary || temporaryQualifier(clause) || calendarDate(clause)
                durable = durable || durableQualifier(clause)
            }
        }
        return temporary && !durable ? .conversation(conversationID) : fact.scope
    }

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func sourceClauses(_ text: String, quoted quote: String) -> [String] {
        let punctuation = CharacterSet(charactersIn: "。；;\n，,")
        var quotedRanges: [Range<String.Index>] = [], search = text.startIndex..<text.endIndex
        while let range = text.range(of: quote, range: search) {
            quotedRanges.append(range)
            search = range.upperBound..<text.endIndex
        }
        var clauses: [String] = [], start = text.startIndex, quotedIndex = 0, qualifier = ""
        func append(_ end: String.Index, continues: Bool = false) {
            let range = start..<end
            while quotedIndex < quotedRanges.count, quotedRanges[quotedIndex].upperBound <= start { quotedIndex += 1 }
            let clause = String(text[range])
            if quotedIndex < quotedRanges.count, quotedRanges[quotedIndex].overlaps(range) { clauses.append(qualifier + clause) }
            // A comma after a standalone "这次" does not change its scope.
            // Carry only explicit qualifiers, never arbitrary previous prose.
            qualifier = continues && has(#"^\s*(?:这次|本次|这趟|这单|此单|本任务|这项任务|当前任务|this (?:time|trip|order|request|task|meeting))\s*$"#, clause) ? clause : ""
        }
        for index in text.indices where text[index].unicodeScalars.allSatisfy({ punctuation.contains($0) }) {
            append(index, continues: text[index] == "，" || text[index] == ",")
            start = text.index(after: index)
        }
        append(text.endIndex)
        return clauses
    }

    private static func amounts(in text: String) -> Set<String> {
        let pattern = #"(?:[¥￥$]\s*)?([0-9]+(?:\.[0-9]+)?)\s*(?:元|块|美元|dollars?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) })
    }

    private static func parameter(in fact: RememberedFact) -> Parameter? {
        let key = fact.key.lowercased()
        // Names, language, timezone and communication style are not task slots.
        if key.hasPrefix("communication.") || ["profile.name", "profile.preferred_name", "profile.language", "profile.timezone", "profile.birthday"].contains(key) { return nil }
        let text = key + " " + fact.text
        if has(#"预算|费用上限|最高价|花费上限|\b(?:budget|spending_limit|price_limit)\b"#, text) { return .budget }
        let taskDomain = has(#"日历|日程|会议|闹钟|提醒|行程|航班|机票|出发|到达|\b(?:calendar|event|meeting|alarm|reminder|travel|flight|trip|task)[._\s-]"#, text)
        if taskDomain, has(#"日期|时间|时长|几点|点[钟半]?|小时|分钟|出发|到达|明天|后天|今天|\b(?:date|time|start|end|duration|departure|arrival|deadline)\b"#, text.replacingOccurrences(of: "_", with: " ")) { return .schedule }
        if has(#"日历|会议|闹钟|提醒|收件|收货|取件|送达|商品|数量|份数|\b(?:calendar|event|meeting|alarm|reminder|delivery|goods|quantity|recipient)[._\s-]"#, text) { return .singleTask }
        return nil
    }

    private static func relevant(_ clause: String, to parameter: Parameter) -> Bool {
        switch parameter {
        case .budget:
            return has(#"预算|费用上限|最高价|花费上限|[0-9]+\s*(?:元|块|美元)|[¥￥$]\s*[0-9]+|\b(?:budget|spending|cost|price|dollars?)\b"#, clause)
        case .schedule:
            return calendarDate(clause) || has(#"日期|时间|时长|几点|[零一二三四五六七八九十两0-9]+\s*(?:点|小时|分钟)|半小时|\b(?:date|time|duration|start|end|minutes?|hours?)\b"#, clause)
        case .singleTask:
            return has(#"日历|会议|闹钟|提醒|收件|收货|取件|送达|商品|数量|份数|[一二三四五六七八九十两0-9]+(?:份|件|个)|\b(?:calendar|meeting|alarm|reminder|delivery|goods|quantity|recipient)\b"#, clause)
        }
    }

    private static func temporaryQualifier(_ clause: String) -> Bool {
        has(#"这次|本次|这趟|这单|此单|本任务|这项任务|当前任务|这场会议|此次行程|这次出行|\b(?:this (?:time|trip|order|request|task|meeting)|for this task)\b"#, clause)
    }

    private static func calendarDate(_ clause: String) -> Bool {
        has(#"今天|明天|后天|今晚|明早|明晚|本周|下周|这周|本月|下月|(?:[0-9]{4}年)?[0-9]{1,2}月[0-9]{1,2}[日号]|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}|\b(?:today|tomorrow|tonight|this week|next week)\b"#, clause)
    }

    private static func durableQualifier(_ clause: String) -> Bool {
        if has(#"以后|今后|往后|每次|每天|每周|每月|每年|通常|一贯|总是|长期|一律|从今天起|从现在起|今天开始|即日起|\b(?:from now on|in future|always|usually|every time|daily|weekly|monthly|yearly|long.term)\b"#, clause) { return true }
        // "这次默认..." is still a single-request parameter. A separate
        // statement of a default remains eligible for personal scope.
        return !temporaryQualifier(clause) && !calendarDate(clause) && has(#"默认|\bby default\b"#, clause)
    }
}
