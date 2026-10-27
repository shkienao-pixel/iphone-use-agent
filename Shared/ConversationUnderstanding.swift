import Foundation

/// Distinguish rejected model decisions from connection failures in evaluation.
struct ConversationRoutingRejection: LocalizedError, Sendable {
    enum Reason: String, Sendable { case malformedOutput, invalidSources, invalidPending, unavailableModule }
    let reason: Reason
    var proposedMode: ConversationRoute.Mode? = nil
    var errorDescription: String? {
        switch reason {
        case .malformedOutput: "未能确定这条消息要执行什么，请补充具体要求"
        case .invalidSources: "意图识别引用了无效的记忆或对话，请重新说明这次要求"
        case .invalidPending: "待补充请求已改变，请重新说明这条补充对应的任务"
        case .unavailableModule: "小红书 MCP 暂未接入。"
        }
    }
}

/// IDs are accepted only from owned envelope fields, never by searching quoted
/// prose for UUIDs. Candidates/expired facts have already been removed by recall.
enum ConversationMemorySources {
    static func ids(in reference: String) -> Set<UUID> {
        guard let data = reference.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let semantic = root["semanticMemory"] as? [String: Any] ?? root
        var result = Set<UUID>()
        for (object, field, key) in [(semantic, "relevantMemories", "id"),
                                     (semantic, "relatedHistory", "sourceID"),
                                     (root, "manualMemories", "id")] {
            for row in object[field] as? [[String: Any]] ?? [] {
                if let raw = row[key] as? String, let id = UUID(uuidString: raw) { result.insert(id) }
            }
        }
        return result
    }

    static func envelope(semantic: String, manual: String) -> String {
        let semanticObject = semantic.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let manualObject = manual.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]
        guard semanticObject != nil || manualObject != nil else { return "" }
        let data = try? JSONSerialization.data(withJSONObject: ["semanticMemory": semanticObject ?? [:],
            "manualMemories": manualObject ?? []], options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// Only source IDs are persisted. Forgetting or removing a source invalidates
/// the pending request; stale text is never copied into a second memory store.
struct ConversationPendingIntent: Codable, Equatable, Sendable {
    let id: UUID
    let originalMessageID: UUID
    let sourceMessageIDs: [UUID]
    let createdAt: Date
    let updatedAt: Date
    let timeZoneIdentifier: String
    var missingInformation: [String]
    var needsRestatement = false
    var expiresAt: Date? = nil
    var clarificationMessageIDs: [UUID]? = nil

    func expired(at now: Date) -> Bool {
        (expiresAt.map { now >= $0 } ?? false) || createdAt.timeIntervalSince(now) > 300
    }
}

enum ConversationTurnSignal {
    private static func matches(_ expression: String, _ text: String) -> Bool {
        text.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Strip examples and quoted payloads before considering explicit limits.
    static func instruction(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*>.*$"#, with: "", options: .regularExpression)
        for pattern in [#"“[^”]*”"#, #"‘[^’]*’"#, #"「[^」]*」"#, #"『[^』]*』"#, #"\"[^\"]*\""#, #"'[^']*'"#, #"`[^`]*`"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func discussionOnly(_ question: String) -> Bool {
        let text = instruction(question).replacingOccurrences(of: #"(?:就叫|叫做|名称(?:是|为)|标题(?:是|为)|命名为)\s*[^，。；;\n]{1,80}"#,
            with: "", options: .regularExpression)
        // Mixed instructions still require semantic interpretation. This gate
        // handles only explicit discussion-only turns, not a keyword classifier.
        if matches(#"(?:然后|接着|随后|之后|同时|并且|并|再|改为|改成|但|不过|完成后|规划后|直接).{0,10}(?:执行|创建|设置|发送|下单|操作|新建|做)"#, text) { return false }
        return matches(#"^(?:请(?:你)?|帮我)?\s*(?:先|暂时|只|仅|本次只|这次只)(?:规划|讨论|解释|分析|聊|写.*(?:草稿|方案))"#, text) ||
            matches(#"(?:先别|暂不|不要|不用|无需)(?:实际)?(?:执行|操作手机)"#, text)
    }

    static func referential(_ question: String) -> Bool {
        let text = instruction(question)
        return matches("刚才|上次|之前|照旧|以前|这个|那个|第二|第[一二三四五六七八九十0-9]+|继续|照着|一样|按惯例", text)
    }

    static func cancelsPending(_ question: String) -> Bool {
        matches(#"^(?:不用了|不需要了|算了|取消这次准备|取消这(?:个|次)(?:请求|安排|设置)|先不安排|先不设置)[。.!！\s]*$"#, instruction(question))
    }

    static func slotLike(_ question: String) -> Bool {
        let text = instruction(question)
        guard text.count <= 120, !discussionOnly(text),
              !matches("怎么|如何|为什么|什么是|帮我|请你|查一下|搜索|另外|换个话题|顺便|取消|算了|不用了|[？?]", text) else { return false }
        return matches(#"^(?:半|\d|[零一二三四五六七八九十两]|今天|明天|后天|下周|周[一二三四五六日天]|上午|下午|晚上|早上|改成|换成|就叫|叫做|名称|每天|工作日|不重复|单次|一次)"#, text) || referential(text)
    }

    /// Stronger than a recall hint: only complete parameter/ordinal fragments
    /// may supply a missing relation; an independent new goal is never folded in.
    static func parameterOnly(_ question: String) -> Bool {
        let text = instruction(question).replacingOccurrences(of: #"^(?:改成|改到|换成|换到)\s*"#, with: "", options: .regularExpression)
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ ")).components(separatedBy: CharacterSet(charactersIn: "，,、"))
        let pattern = #"^(?:半小时|[零一二三四五六七八九十两\d]+(?:个半小时|小时|分钟|分钟半)|第?[零一二三四五六七八九十两\d]+(?:个|项|条)|不重复|单次|一次|每天|工作日|(?:今天|明天|后天|大后天|下周[一二三四五六日天])(?:(?:上午|下午|晚上|早上)?[零一二三四五六七八九十两\d]+(?:[:：点时])[零一二三四五六七八九十两\d]*(?:分|半)?)?|(?:上午|下午|晚上|早上)?[零一二三四五六七八九十两\d]+(?:[:：点时])[零一二三四五六七八九十两\d]*(?:分|半)?)$"#
        return !parts.isEmpty && parts.allSatisfy { matches(pattern, $0.trimmingCharacters(in: .whitespaces)) }
    }
}

enum ConversationWorkingMemory {
    static let recentLimit = 12
    static let maximumSources = 24
    static let maximumPendingSourceBytes = 24_000

    /// Relative day requests retain their original day boundary. Non-temporal
    /// writing/planning requests do not expire merely because a day elapsed.
    static func expiry(for text: String, at date: Date, timeZone: String) -> Date? {
        let text = ConversationTurnSignal.instruction(text).replacingOccurrences(of: #"(?:就叫|名叫|叫做|名称(?:是|为|叫)|标题(?:是|为)|命名为)\s*[^，。；;\n]{1,80}"#,
            with: "", options: .regularExpression)
        let periods = ["大后天": 3, "后天": 2, "明天": 1, "明早": 1, "明晚": 1, "今天": 0, "今晚": 0, "今早": 0]
        let expression = try? NSRegularExpression(pattern: "大后天|后天|明天|明早|明晚|今天|今晚|今早")
        guard let match = expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text), let day = periods[String(text[range])],
              let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(byAdding: .day, value: day + 1, to: calendar.startOfDay(for: date))
    }

    static func refreshesDate(_ question: String, at now: Date) -> Bool {
        let text = ConversationTurnSignal.instruction(question)
        guard text.range(of: #"^(?:改成|改到|换成|换到|重新安排到)?(?:今天|明天|后天|大后天|明早|明晚)"#, options: .regularExpression) != nil,
              let expiry = expiry(for: text, at: now, timeZone: TimeZone.current.identifier) else { return false }
        return expiry > now
    }

    static func pending(in history: [AssistantMessage]) -> ConversationPendingIntent? {
        guard let index = history.lastIndex(where: { $0.role == "assistant" }),
              history[index].intent?.mode == .clarify else { return nil }
        let assistant = history[index]
        if var pending = assistant.intent?.pending {
            let sources = Set(history.filter { $0.role == "user" && $0.taskID == nil }.map(\.id))
            guard pending.id == assistant.id, pending.sourceMessageIDs.count <= maximumSources,
                  Set(pending.sourceMessageIDs).count == pending.sourceMessageIDs.count,
                  pending.sourceMessageIDs.contains(pending.originalMessageID),
                  pending.createdAt.timeIntervalSince1970.isFinite, pending.updatedAt.timeIntervalSince1970.isFinite,
                  TimeZone(identifier: pending.timeZoneIdentifier) != nil,
                  !pending.missingInformation.isEmpty, pending.missingInformation.count <= 8,
                  pending.missingInformation.allSatisfy({ !$0.isEmpty && $0.count <= 120 }),
                  sources.contains(pending.originalMessageID),
                  Set(pending.sourceMessageIDs).isSubset(of: sources) else { return nil }
            if pending.clarificationMessageIDs == nil {
                // Recover the questions that existing parameter answers refer
                // to. An ordinal is meaningless without its actual options.
                var questions: [UUID] = []
                for sourceID in pending.sourceMessageIDs.dropFirst() {
                    guard let position = history.firstIndex(where: { $0.id == sourceID }), position > 0,
                          let question = history[..<position].last(where: { $0.role == "assistant" }),
                          question.intent?.mode == .clarify else { pending.needsRestatement = true; continue }
                    if !questions.contains(question.id) { questions.append(question.id) }
                }
                if !questions.contains(pending.id) { questions.append(pending.id) }
                pending.clarificationMessageIDs = questions
            }
            let questions = pending.clarificationMessageIDs ?? []
            let availableQuestions = Set(history.filter { $0.role == "assistant" && $0.taskID == nil }.map(\.id))
            guard questions.count <= maximumSources, Set(questions).count == questions.count,
                  questions.last == pending.id, Set(questions).isSubset(of: availableQuestions) else { return nil }
            if pending.expiresAt == nil, let original = history.first(where: { $0.id == pending.originalMessageID }) {
                pending.expiresAt = expiry(for: original.text, at: original.createdAt, timeZone: original.timeZoneIdentifier ?? pending.timeZoneIdentifier)
            }
            return pending
        }
        // Bounded migration for pre-ledger archives. No inference from old
        // summaries or a completed task is accepted as a pending instruction.
        let missing = assistant.intent?.missingInformation ?? []
        guard !missing.isEmpty, missing.count <= 8, missing.allSatisfy({ !$0.isEmpty && $0.count <= 120 }), index > 0,
              history[index - 1].role == "user", history[index - 1].taskID == nil else { return nil }
        let original = history[index - 1]
        return .init(id: assistant.id, originalMessageID: original.id, sourceMessageIDs: [original.id],
            createdAt: original.createdAt, updatedAt: assistant.createdAt,
            timeZoneIdentifier: original.timeZoneIdentifier ?? TimeZone.current.identifier, missingInformation: assistant.intent?.missingInformation ?? [],
            expiresAt: expiry(for: original.text, at: original.createdAt, timeZone: original.timeZoneIdentifier ?? TimeZone.current.identifier),
            clarificationMessageIDs: [assistant.id])
    }

    static func selectedHistory(_ history: [AssistantMessage]) -> [AssistantMessage] {
        let eligible = history.filter { ["user", "assistant"].contains($0.role) }
        var ids = Set(eligible.suffix(recentLimit).map(\.id))
        if let pending = pending(in: eligible) {
            ids.formUnion(pending.sourceMessageIDs); ids.formUnion(pending.clarificationMessageIDs ?? [])
        }
        return eligible.filter { ids.contains($0.id) }
    }

    static func recallQuery(question: String, history: [AssistantMessage]) -> String {
        guard !ConversationTurnSignal.discussionOnly(question) else { return question }
        var anchors: [String] = []
        if let pending = pending(in: history), ConversationTurnSignal.slotLike(question) || ConversationTurnSignal.referential(question),
           let original = history.first(where: { $0.id == pending.originalMessageID }) {
            anchors.append(original.text)
        } else if ConversationTurnSignal.referential(question), let original = history.last(where: { $0.role == "user" }) {
            anchors.append(original.text)
        }
        guard !anchors.isEmpty else { return question }
        let reference = anchors.map { ConversationReferenceText.excerpt($0, characters: 1600, jsonCharacters: 2400) }.joined(separator: "\n")
        return String((question + "\n用于本机记忆检索的当前会话背景：\n" + reference).prefix(4000))
    }

    static func record(route: ConversationRoute, user: AssistantMessage, replyID: UUID,
                       history: [AssistantMessage], now: Date = Date()) -> ConversationIntentRecord {
        var record = route.record
        guard route.mode == .clarify, !(route.missingInformation ?? []).isEmpty else { return record }
        let prior = pending(in: history)
        let continues = prior != nil && route.relation == .answer && route.pendingIntentID == prior?.id
        var ids = continues ? prior?.sourceMessageIDs ?? [] : []
        ids.append(user.id)
        let unique = ids.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        var questions = continues ? prior?.clarificationMessageIDs ?? [] : []
        questions.append(replyID)
        let retainedQuestions = questions.count <= maximumSources ? questions : Array(questions.prefix(maximumSources - 1)) + [replyID]
        record.pending = .init(id: replyID, originalMessageID: continues ? prior!.originalMessageID : user.id,
            sourceMessageIDs: Array(unique.prefix(maximumSources)), createdAt: continues ? prior!.createdAt : user.createdAt,
            updatedAt: now, timeZoneIdentifier: continues ? prior!.timeZoneIdentifier : user.timeZoneIdentifier ?? TimeZone.current.identifier,
            missingInformation: route.missingInformation ?? [], needsRestatement: unique.count > maximumSources || questions.count > maximumSources ||
                (continues && prior!.needsRestatement) || ["missingPending", "incompletePending"].contains(route.decisionSource ?? ""),
            expiresAt: expiry(for: user.text, at: user.createdAt, timeZone: user.timeZoneIdentifier ?? TimeZone.current.identifier) ?? (continues ? prior!.expiresAt : nil),
            clarificationMessageIDs: retainedQuestions)
        return record
    }
}

/// A process-local source binding. A model or an archived intent cannot create
/// this value through ConversationRoute's Codable representation.
struct ConversationFlightSelection: Equatable, Sendable {
    let source: AssistantMessage
    let offer: CtripFlightOffer
    let requestedAt: Date
    let timeZoneIdentifier: String
}

struct ConversationFlightOpenAuthorization: Equatable, Sendable {
    let conversationID: UUID
    let userMessageID: UUID
    let requestToken: UUID
    let presentationRevision: UUID
}

/// A deliberately narrow local action grammar: selecting a displayed flight
/// opens its price page only. Comparisons, changed constraints and purchases
/// remain ordinary routing/clarification; no model index grants authority.
enum ConversationFlightSelectionResolver {
    static let maximumSourceAge: TimeInterval = 30 * 60

    static func route(question: String, history: [AssistantMessage], now: Date,
                      timeZoneIdentifier: String, hasPendingClarification: Bool = false) -> ConversationRoute? {
        let original = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard original.count <= 120, ConversationTurnSignal.instruction(original) == original,
              !ConversationTurnSignal.discussionOnly(original) else { return nil }
        let text = original.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression).uppercased()
        let source = latestSource(in: history)
        if source != nil, text.range(of: #"预订|订票|下单|支付|付款|买票|购买|就订"#, options: .regularExpression) != nil,
           text.range(of: #"航班|机票|这班|第[一二三四五六七八九十0-9]+班|[A-Z0-9]{2}\d{3,4}"#, options: .regularExpression) != nil {
            return clarification("请先打开所选航班的选价页核对票价；下单和付款需要你在携程确认。")
        }
        let number = #"(?:[1-9]\d?|[一二三四五六七八九十两]{1,3})"#
        let reference = #"(?:倒数第"# + number + #"班|第"# + number + #"(?:班|个|趟)(?:航班)?|最后一班|首班(?:航班)?|这一班|这班(?:航班)?|这个航班|它|[A-Z0-9]{2}\d{3,4})"#
        let pattern = #"^(?:请帮我|请你|麻烦你|麻烦|请|帮我)?(?:直接)?(?:(?:打开|查看|去看|看|选择|就选|就要|选|要|就)(?:一下)?)?("# + reference + #")(?:的)?(?:选价页|票价页|详情页|详情|航班)?(?:吧|就行|就可以)?[。！!]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let selectedReference = String(text[range])
        let explicitFlightReference = selectedReference.contains("班") || !CtripFlightParser.flightNumbers(in: selectedReference).isEmpty
        let latestAssistant = history.last { $0.role == "assistant" }
        let continuesFlightClarification = latestAssistant?.intent?.mode == .clarify &&
            latestAssistant?.intent?.diagnostics?.decisionSource == "localFlightSelection"
        // Generic "第二个/它" belongs to the newest visible selection context,
        // never an older flight hidden behind a newer restaurant/task answer.
        if !explicitFlightReference, latestAssistant?.id != source?.id, !continuesFlightClarification { return nil }
        // A short ordinal must not answer a different pending form by accident.
        if hasPendingClarification, !continuesFlightClarification,
           (!explicitFlightReference || text.range(of: #"打开|查看|去看|选价页|票价页"#, options: .regularExpression) == nil) { return nil }
        guard let source else { return clarification("当前对话还没有可选的航班结果，请先查询航班。") }
        guard fresh(source, now: now) else { return clarification("这份航班结果已过期，请重新查询后再选择。") }
        let offers = displayedOffers(source: source, history: history)
        guard !offers.isEmpty else { return clarification("最新一次查询没有可选航班，请先重新查询。") }
        let matches: [CtripFlightOffer]
        let codes = CtripFlightParser.flightNumbers(in: selectedReference)
        if codes.count == 1, let code = codes.first {
            matches = offers.filter { CtripFlightParser.flightNumbers(in: $0.title) == [code] }
        } else if ["这一班", "这班", "这班航班", "这个航班", "它"].contains(selectedReference) {
            matches = offers.count == 1 ? offers : []
        } else {
            let reverse = selectedReference.hasPrefix("倒数") || selectedReference == "最后一班"
            let digits = selectedReference.replacingOccurrences(of: #"倒数|第|班|个|趟|航|最后|首"#, with: "", options: .regularExpression)
            let ordinal = ["首班", "首班航班", "最后一班"].contains(selectedReference) ? 1 : numberValue(digits)
            let index = ordinal.map { reverse ? offers.count - $0 : $0 - 1 }
            matches = index.flatMap { offers.indices.contains($0) ? [offers[$0]] : nil } ?? []
        }
        guard matches.count == 1, let offer = matches.first else {
            return clarification("请明确要打开的航班号，或说明当前结果中的第几班。")
        }
        guard (offer.preferredNativeFlightSelectionURL != nil || offer.nativeFlightSelectionLookupQuery != nil),
              departureHasNotPassed(offer, now: now) else {
            return clarification("这班航班的信息还不足以直接打开选价页，或出发时间已过，请重新查询这班航班后再试。")
        }
        var result = ConversationRoute(mode: .flightOpen, request: original,
            message: "正在准备打开 " + offer.cardTitle + " 的选价页。", relatedMessageIDs: [source.id], relation: .reference)
        result.decisionSource = "localFlightSelection"
        result.flightSelection = .init(source: source, offer: offer, requestedAt: now, timeZoneIdentifier: timeZoneIdentifier)
        return result
    }

    static func isCurrent(_ selection: ConversationFlightSelection, history: [AssistantMessage], now: Date) -> Bool {
        guard let source = latestSource(in: history), source == selection.source, fresh(source, now: now),
              now.timeIntervalSince(selection.requestedAt) >= -5,
              now.timeIntervalSince(selection.requestedAt) <= 60,
              (selection.offer.preferredNativeFlightSelectionURL != nil || selection.offer.nativeFlightSelectionLookupQuery != nil),
              departureHasNotPassed(selection.offer, now: now) else { return false }
        return displayedOffers(source: source, history: history).contains(selection.offer)
    }

    private static func latestSource(in history: [AssistantMessage]) -> AssistantMessage? {
        history.last { $0.role == "assistant" && ($0.flightOffers != nil || $0.flightQuery != nil) }
    }
    private static func displayedOffers(source: AssistantMessage, history: [AssistantMessage]) -> [CtripFlightOffer] {
        guard let saved = source.flightOffers else { return [] }
        let prior = history.firstIndex { $0.id == source.id }.flatMap { history[..<$0].last { $0.role == "user" }?.text }
        let query = source.flightQuery ?? saved.first?.query ?? prior ?? ""
        let rebuilt = CtripFlightParser.offers(source.text, query: query, at: source.createdAt)
        let offers = rebuilt.isEmpty ? CtripFlightParser.legacyFallbackOffers(saved, in: source.text) : rebuilt
        return CtripFlightParser.displayOrder(source.text, representedBy: offers)
    }
    private static func fresh(_ source: AssistantMessage, now: Date) -> Bool {
        let age = now.timeIntervalSince(source.createdAt)
        return age.isFinite && age >= -300 && age <= maximumSourceAge
    }
    private static func departureHasNotPassed(_ offer: CtripFlightOffer, now: Date) -> Bool {
        // This native contract is domestic China. Flight clocks use the departure
        // airport's UTC+8, regardless of the person's current device timezone.
        let departure = offer.leg(departure: true)
        if departure.time == "待核对", offer.nativeFlightSelectionLookupQuery != nil,
           let url = offer.nativeFlightListURL,
           let compact = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "c4" })?.value {
            let today = DateFormatter(); today.calendar = Calendar(identifier: .gregorian)
            today.locale = Locale(identifier: "en_US_POSIX"); today.timeZone = TimeZone(identifier: "Asia/Shanghai")
            today.dateFormat = "yyyyMMdd"
            return compact >= today.string(from: now)
        }
        guard departure.date.range(of: #"^20\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              departure.time.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        guard let instant = formatter.date(from: departure.date + " " + departure.time) else { return false }
        return instant > now
    }
    private static func numberValue(_ text: String) -> Int? {
        if let value = Int(text), (1...99).contains(value) { return value }
        let digits: [Character:Int] = ["一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if text == "十" { return 10 }
        if text.count == 1 { return text.first.flatMap { digits[$0] } }
        let parts = text.split(separator: "十", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count <= 1 }),
              let tens = parts[0].isEmpty ? 1 : parts[0].first.flatMap({ digits[$0] }),
              let ones = parts[1].isEmpty ? 0 : parts[1].first.flatMap({ digits[$0] }) else { return nil }
        return tens * 10 + ones
    }
    private static func clarification(_ message: String) -> ConversationRoute {
        var route = ConversationRoute(mode: .clarify, request: "", message: message, missingInformation: ["航班选择"], relation: .reference)
        route.decisionSource = "localFlightSelection"
        return route
    }
}
