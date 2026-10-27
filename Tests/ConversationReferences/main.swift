import Foundation

@main struct ConversationReferenceChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func payload(_ context: String) throws -> (tasks: [[String: String]], offers: [[String: Any]]) {
            let object = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
            return (object["tasks"] as! [[String: String]], object["flightOffers"] as! [[String: Any]])
        }
        func viewModel(_ text: String = "正常任务") -> (PhoneAgentViewModel, [ReferenceRecord]) {
            let records = (0..<3).map { _ -> ReferenceRecord in
                var record = ReferenceRecord(); record.effectiveGoal = text; record.summary = text
                record.logs = [.init(title: "工具回执", detail: text)]; return record
            }
            let vm = PhoneAgentViewModel(); vm.history.records = records
            vm.engine.currentRecord = records[0]; vm.engine.hasCurrentTask = true
            return (vm, records)
        }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func offer(_ text: String, query: String? = nil) -> CtripFlightOffer {
            .init(id: "fixture", title: text, details: text, price: "900元", bookingURL: nil, query: query ?? text, queriedAt: at)
        }
        func history(_ records: [ReferenceRecord], offers: [CtripFlightOffer], text: String) -> [AssistantMessage] {
            records.flatMap { record in [AssistantMessage(role: "user", text: "查询", createdAt: at),
                AssistantMessage(role: "assistant", text: text, createdAt: at, flightOffers: offers, taskID: record.id)] }
        }
        func checkBounds(_ context: String, history: [AssistantMessage], label: String) {
            expect(context.count <= 64_000, label + ": historical references fit the routing character budget")
            expect(context.utf8.count <= 250_000, label + ": historical references also bound grapheme byte expansion")
            let input = try? ConversationRoutingInput(question: "一个简短的新问题", history: history, taskContext: context)
            expect(input?.question == "一个简短的新问题", label + ": history cannot block or replace a short current question")
        }
        let empty = PhoneAgentViewModel()
        let emptyPayload = try payload(empty.unifiedTaskContext(history: []))
        expect(emptyPayload.tasks.isEmpty && emptyPayload.offers.isEmpty, "Empty history has no invented reference records")
        func contextObject(_ context: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
        }
        let origin = empty.conversation.currentConversationID, otherOrigin = UUID()
        let persistedCard = PaotuiChatCard(conversationID: origin, kind: "confirm", title: "旧报价")
        let persistedOnly = try contextObject(empty.unifiedTaskContext(history: [.init(role: "assistant", text: "旧卡", paotuiCard: persistedCard)]))
        expect(persistedOnly["paotuiConversationActive"] as? Bool == false && persistedOnly["paotuiSession"] is NSNull,
            "Persisted last-card evidence cannot establish an active errands session")
        empty.conversation.paotuiSummaries[origin] = ["active": true, "phase": "quoted", "goods": "A 的水"]
        empty.conversation.paotuiSummaries[otherOrigin] = ["active": false, "phase": "outcome", "goods": "B 的回执"]
        let liveSummary = try contextObject(empty.unifiedTaskContext(history: []))
        expect(liveSummary["paotuiConversationActive"] as? Bool == true && (liveSummary["paotuiSession"] as? [String: Any])?["goods"] as? String == "A 的水",
            "Routing uses the actual live summary even without a persisted last card")
        let explicitOrigin = try contextObject(empty.unifiedTaskContext(history: [], originatingConversationID: otherOrigin))
        expect(explicitOrigin["paotuiConversationActive"] as? Bool == false && (explicitOrigin["paotuiSession"] as? [String: Any])?["goods"] as? String == "B 的回执",
            "An explicit originating conversation selects its own module summary")
        empty.conversation.paotuiSummaries = [:]
        let (normal, normalRecords) = viewModel()
        let normalOffer = offer("MU5101 上海到北京", query: "明天上海到北京，直飞，2人")
        let normalMessages = history(normalRecords, offers: [normalOffer], text: "普通查询结果")
        let normalPayload = try payload(normal.unifiedTaskContext(history: normalMessages))
        expect(normalPayload.tasks.first?["id"] == normalRecords[0].id.uuidString && normalPayload.tasks.first?["active"] == "true", "Current task identity and activity survive reference packing")
        expect(normalPayload.tasks.allSatisfy { $0["goal"] == "正常任务" && $0["summary"] == "正常任务" && $0["verifiedToolReceipts"] == "正常任务" }, "Ordinary task goals, summaries and receipts remain verbatim")
        expect(normalPayload.offers.allSatisfy { $0["title"] as? String == normalOffer.title && $0["query"] as? String == normalOffer.query && $0["details"] as? String == normalOffer.details }, "Ordinary flight fields remain verbatim")
        let interrupted = normalMessages + (0..<14).map { AssistantMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "穿插的普通聊天") }
        let resumedFlights = try payload(empty.unifiedTaskContext(history: interrupted))
        expect(resumedFlights.offers.count == 1 && resumedFlights.offers.first?["query"] as? String == normalOffer.query,
               "Flight follow-ups survive more than six unrelated messages without duplicating earlier result sets")
        let newer = offer("CA1501 北京到成都", query: "2026-10-28北京到成都1人经济舱")
        let switched = try payload(empty.unifiedTaskContext(history: normalMessages + [.init(role: "assistant", text: "新路线结果", flightOffers: [newer])]))
        expect(switched.offers.count == 1 && switched.offers.first?["title"] as? String == newer.title,
               "A new route replaces the earlier candidate set; second-flight references never mix searches")
        let noResults = normalMessages + [AssistantMessage(role: "user", text: "改查北京到成都"), .init(role: "assistant", text: "没有符合条件的航班", flightOffers: [])]
        let noResultsPayload = try payload(empty.unifiedTaskContext(history: noResults))
        expect(noResultsPayload.offers.isEmpty,
               "A successful query with zero results clears stale earlier bookable candidates")
        let unrelated = ReferenceRecord(); normal.history.records.append(unrelated)
        let scoped = try payload(normal.unifiedTaskContext(history: normalMessages))
        expect(scoped.tasks.count == 3 && !scoped.tasks.contains { $0["id"] == unrelated.id.uuidString }, "Unlinked task records stay out of context")

        let (parallel, linked) = viewModel(String(repeating: "任务\\\"原始说明", count: 1000))
        let nativeRecords = (0..<20).map { _ -> ReferenceRecord in
            var record = ReferenceRecord(); record.executionLane = "native"
            record.effectiveGoal = String(repeating: "后台任务\\\"参数", count: 1000); return record
        }
        parallel.backgroundTasks.records = nativeRecords
        parallel.backgroundTasks.activeIDs = Set(nativeRecords.map(\.id))
        let screenMessages = history(linked, offers: (0..<24).map { offer("MU\(4000 + $0) " + String(repeating: "\\\"航班条件", count: 1000)) }, text: "候选")
        let isolatedParallelPayload = try payload(parallel.unifiedTaskContext(history: screenMessages))
        expect(!isolatedParallelPayload.tasks.contains { $0["execution"] == "native" },
               "Active native tasks from other conversations cannot enter the current chat context")
        let parallelMessages = screenMessages + nativeRecords.map {
            AssistantMessage(role: "assistant", text: "本对话原生任务", taskID: $0.id)
        }
        let parallelContext = parallel.unifiedTaskContext(history: parallelMessages)
        let parallelPayload = try payload(parallelContext)
        expect(Set(nativeRecords.map { $0.id.uuidString }).isSubset(of: Set(parallelPayload.tasks.map { $0["id"]! })),
               "Every linked active native task keeps its actual ID even beside long flight references")
        expect(parallelPayload.offers.count == 24 && parallelContext.count <= 64_000 && parallelContext.utf8.count <= 250_000,
               "Twenty native tasks, screen task and twenty-four flight cards share a bounded wire context")
        expect(parallelPayload.tasks.filter { $0["execution"] == "native" }.count == 20,
               "Native scheduling hints remain attached to their actual task IDs")

        // This is the original valid Ctrip history regression, through its real decoder and parser.
        let query = String(repeating: "航线日期人数约束", count: 500)
        let raw = "# MU5101 " + String(repeating: "甲", count: 5800) + "\n出发时间：2026-11-01 08:00\n价格：900元\n" +
            "# CA1501 " + String(repeating: "乙", count: 5800) + "\n出发时间：2026-11-01 09:00\n价格：1000元\n"
        let decoded = try CtripClient.decode(JSONSerialization.data(withJSONObject: ["result": raw]), token: "offline-fixture-token")
        let parsedOffers = CtripFlightParser.offers(decoded, query: query, at: at)
        expect(query.count == 4000 && decoded.count <= 12000 && parsedOffers.count == 2, "Original fixture stays inside actual Ctrip query and reply limits")
        let (long, records) = viewModel(String(repeating: "任务摘要观察", count: 1000))
        let messages = history(records, offers: parsedOffers, text: decoded)
        let originalMessages = messages, originalRecords = long.history.records
        let context = long.unifiedTaskContext(history: messages), longPayload = try payload(context)
        checkBounds(context, history: messages, label: "Valid long flight replies")
        expect(longPayload.offers.count == 2 && longPayload.offers.allSatisfy { $0["query"] as? String == query }, "The latest result set retains complete queries without duplicating previous searches")
        expect(longPayload.offers.allSatisfy { ($0["title"] as? String)?.contains("历史节选") == true }, "Long reference titles explicitly mark excerpts")
        expect(messages == originalMessages && long.history.records == originalRecords && parsedOffers.first!.title.count > 5800, "Reference packing never mutates original messages, task records or offer cards")

        let middleTitle = String(repeating: "甲", count: 5900) + " MU5101 " + String(repeating: "乙", count: 5800)
        let middleReply = try CtripClient.decode(JSONSerialization.data(withJSONObject: ["result": "# " + middleTitle + "\n价格：900元"]), token: "offline-fixture-token")
        let middleOffers = CtripFlightParser.offers(middleReply, query: "明天直飞2人", at: at)
        let middle = try payload(empty.unifiedTaskContext(history: [.init(role: "assistant", text: middleReply, flightOffers: middleOffers)]))
        expect((middle.offers.first?["flightNumbers"] as? [String]) == ["MU5101"], "A flight number in the middle of a long parsed title survives separately")
        let constraints = "出发2030-01-01｜只要直飞｜2名成人"
        let endQuery = String(repeating: "q", count: 4000 - constraints.count) + constraints
        let endPayload = try payload(empty.unifiedTaskContext(history: [.init(role: "assistant", text: "result", flightOffers: [offer("CA1501", query: endQuery)])]))
        expect(endPayload.offers.first?["query"] as? String == endQuery, "Date, direct-flight and passenger constraints at the query end remain available")
        let escapedQuery = "起点上海 " + String(repeating: "\"\\\u{0001}", count: 3000) + " 终点北京 明天直飞2人"
        let escapedPayload = try payload(empty.unifiedTaskContext(history: [.init(role: "assistant", text: "result", flightOffers: [offer("MU5101", query: escapedQuery)])]))
        let escapedReference = escapedPayload.offers.first?["query"] as? String ?? ""
        expect(escapedReference.hasPrefix("起点上海") && escapedReference.hasSuffix("明天直飞2人") && escapedReference.contains("历史节选"), "Escaped overlong query reference retains both ends and marks omitted history")

        let giantGrapheme = "a" + String(repeating: "\u{0301}", count: 20_000)
        let families = [
            ("quotes/slashes/control", String(repeating: "\"\\\u{0001}", count: 6000)),
            ("CRLF", String(repeating: "\r\n", count: 8000)),
            ("Chinese", String(repeating: "航班", count: 7000)),
            ("joined emoji", String(repeating: "👩🏽‍💻", count: 5000)),
            ("one enormous grapheme", giantGrapheme),
        ]
        var generatedContexts: [String: String] = [:]
        for (label, value) in families {
            let (vm, fixtures) = viewModel(value)
            let fixtureMessages = history(fixtures, offers: [offer(value), offer(value)], text: value)
            let snapshot = fixtureMessages, snapshotRecords = vm.history.records
            let packed = vm.unifiedTaskContext(history: fixtureMessages)
            checkBounds(packed, history: fixtureMessages, label: label)
            let input = try? ConversationRoutingInput(question: "当前问题", history: fixtureMessages, taskContext: packed)
            let historical = input?.turns.dropFirst().dropLast().compactMap { $0["content"] } ?? []
            expect(!historical.isEmpty && historical.allSatisfy { $0.utf8.count < 10_000 }, label + ": ordinary historical turns also have bounded serialized expansion")
            expect(fixtureMessages == snapshot && vm.history.records == snapshotRecords, label + ": long Unicode/escaped originals remain intact")
            generatedContexts[label] = packed
        }
        let historyInput = try ConversationRoutingInput(question: "最新问题", history: [.init(role: "user", text: giantGrapheme)], taskContext: "{}")
        expect((historyInput.turns.first?["content"]?.utf8.count ?? Int.max) < 10_000, "A huge historical grapheme cannot bypass excerpt byte bounds")
        expect(historyInput.turns.last?["content"] == "最新问题", "Byte-bounded history leaves the latest human turn separate")

        let ordered = (0..<20).map { index in offer("MU\(1000 + index)", query: "query-\(index)") }
        let orderMessages: [AssistantMessage] = [.init(role: "assistant", text: "old", flightOffers: Array(ordered.prefix(8))),
            .init(role: "user", text: "follow-up"), .init(role: "assistant", text: "new", flightOffers: Array(ordered.suffix(12)))]
        let orderPayload = try payload(empty.unifiedTaskContext(history: orderMessages))
        expect(orderPayload.offers.compactMap { $0["query"] as? String } == ordered.suffix(12).map(\.query), "All twelve displayed candidates preserve ordinal positions without mixing earlier results")
        expect(orderPayload.offers.compactMap { $0["position"] as? Int } == Array(1...12), "Seventh and later flight references keep their visible card positions")
        let twelveLongMessages = [AssistantMessage(role: "assistant", text: "十二个候选", flightOffers: (0..<12).map { index in
            offer("MU\(1000 + index)", query: query)
        }, flightQuery: query)]
        let twelveContext = empty.unifiedTaskContext(history: twelveLongMessages)
        checkBounds(twelveContext, history: twelveLongMessages, label: "Twelve candidates with complete search conditions")
        let twelveObject = try JSONSerialization.jsonObject(with: Data(twelveContext.utf8)) as! [String: Any]
        expect((twelveObject["flightSearch"] as? [String: Any])?["query"] as? String == query,
               "Shared flight search keeps the complete 4000-character request when all twelve card references are packed")
        let fullSearchStart = "2026-10-26 北京到深圳 1名成人经济舱，可接受中转。"
        let fullSearchEnd = "最晚晚上到达深圳；税费仅采用实际返回。"
        let fullSearchQuery = fullSearchStart + String(repeating: "行", count: 4000 - fullSearchStart.count - fullSearchEnd.count) + fullSearchEnd
        let twentyFourOrdered = (0..<24).map { index in offer("MU\(2000 + index)", query: "new-query-\(index)") }
        let twentyFourMessages = orderMessages + [AssistantMessage(role: "user", text: "改查北京到深圳"),
            .init(role: "assistant", text: "二十四个完整候选", flightOffers: twentyFourOrdered, flightQuery: fullSearchQuery)]
        let twentyFourContext = empty.unifiedTaskContext(history: twentyFourMessages)
        let twentyFourPayload = try payload(twentyFourContext)
        checkBounds(twentyFourContext, history: twentyFourMessages, label: "Twenty-four ordered candidates")
        expect(twentyFourPayload.offers.count == 24 && twentyFourPayload.offers.compactMap { $0["position"] as? Int } == Array(1...24),
               "All twenty-four displayed candidates retain complete ordinal positions")
        expect(twentyFourPayload.offers.compactMap { $0["query"] as? String } == twentyFourOrdered.map(\.query),
               "Twenty-four candidates come only from the newest search without mixing earlier routes")
        expect(twentyFourPayload.offers[15]["flightNumbers"] as? [String] == ["MU2015"] && twentyFourPayload.offers[15]["position"] as? Int == 16,
               "The sixteenth candidate remains identifiable independently of title excerpts")
        let twentyFourObject = try JSONSerialization.jsonObject(with: Data(twentyFourContext.utf8)) as! [String: Any]
        expect((twentyFourObject["flightSearch"] as? [String: Any])?["query"] as? String == fullSearchQuery &&
               (twentyFourObject["flightSearch"] as? [String: Any])?["resultCount"] as? Int == 24,
               "The complete shared query and actual result count accompany all twenty-four references")
        let thirtyRaw = (1...30).map { index in
            "### 航班\(index)：MU\(4000 + index)\n出发时间：2026-10-26 08:00\n价格：\(900 + index)元"
        }.joined(separator: "\n\n")
        let thirtyParsed = CtripFlightParser.offers(thirtyRaw, query: fullSearchQuery, at: at)
        let thirtyMessages = [AssistantMessage(role: "assistant", text: thirtyRaw, createdAt: at, flightOffers: thirtyParsed, flightQuery: fullSearchQuery)]
        let thirtySearch = CtripFlightSearchContext.latest(in: thirtyMessages)!
        let thirtyContext = empty.unifiedTaskContext(history: thirtyMessages)
        let thirtyPayload = try payload(thirtyContext)
        expect(thirtyParsed.count == 30 && thirtySearch.offers.count == 30, "Thirty synthetic source candidates survive the actual parser and conversation search")
        print("THIRTY_CANDIDATE_REPRO: parsed=\(thirtyParsed.count), local=\(thirtySearch.offers.count), referencePositions=\(thirtyPayload.offers.compactMap { $0["position"] as? Int })")
        expect(thirtyPayload.offers.contains { $0["position"] as? Int == 30 }, "The thirtieth visible candidate is available to model reference")
        checkBounds(thirtyContext, history: thirtyMessages, label: "Thirty candidates sampled into twenty-four reference rows")
        let thirtyObject = try JSONSerialization.jsonObject(with: Data(thirtyContext.utf8)) as! [String: Any]
        let thirtyMetadata = thirtyObject["flightSearch"] as! [String: Any]
        expect(thirtyPayload.offers.count == 24 && thirtyPayload.offers.first?["position"] as? Int == 1,
               "A bounded sample keeps the first and last global UI positions")
        expect(thirtyMetadata["resultCount"] as? Int == 30 && thirtyMetadata["referenceCount"] as? Int == 24 &&
               thirtyMetadata["referencesOmitted"] as? Bool == true && thirtyMetadata["omittedReferenceCount"] as? Int == 6,
               "Reference metadata discloses the full local count and omitted sample rows")
        expect((twentyFourObject["flightSearch"] as? [String: Any])?["referencesOmitted"] as? Bool == false,
               "A complete twenty-four-row reference set does not claim omissions")
        var focusPositions: [String: [Int]] = [:]
        for (question, expected) in [("第27个航班的行李额度呢？", 27), ("第二十七个呢？", 27),
            ("第30个呢？", 30), ("第三十个呢？", 30), ("最后一个呢？", 30),
            ("倒数第三个呢？", 28), ("倒数第3个呢？", 28), ("倒3", 28)] {
            let focused = empty.unifiedTaskContext(history: thirtyMessages, question: question)
            let rows = try payload(focused).offers, positions = rows.compactMap { $0["position"] as? Int }
            expect(positions.count == 24 && positions == positions.sorted() && Set(positions).count == 24 &&
                   positions.contains(1) && positions.contains(30) && positions.contains(expected),
                   question + ": explicit focus retains global UI positions, anchors and the row budget")
            expect(rows.first(where: { $0["position"] as? Int == expected })?["flightNumbers"] as? [String] == ["MU\(4000 + expected)"],
                   question + ": the focused row identifies the actual globally sorted flight")
            checkBounds(focused, history: thirtyMessages, label: question)
            focusPositions[question] = positions
        }
        for question in ["27元以内，30号出发，3个人", "便宜那个呢？", "后面那个的行李呢？", "第27天的机票", "第27.5个", "倒数三个航班", "倒数3个", "最后到达的是谁？"] {
            expect(CtripFlightSearchContext.explicitReferencePositions(question, resultCount: 30).isEmpty,
                   question + ": prices, dates, counts and ambiguous references are not candidate ordinals")
        }
        expect(CtripFlightSearchContext.explicitReferencePositions("第0个、第31个、倒数第31个", resultCount: 30).isEmpty,
               "Out-of-range ordinals cannot be clamped into a different candidate")
        let staleInstructionMessages = thirtyMessages + [.init(role: "user", text: "第27个，帮我订这个航班")]
        let noQuestionPositions = try payload(empty.unifiedTaskContext(history: staleInstructionMessages)).offers.compactMap { $0["position"] as? Int }
        expect(!noQuestionPositions.contains(27), "A missing current question never promotes a historical selection or booking request into focus")
        let thirtySnapshot = thirtyMessages, thirtyIDs = thirtySearch.offers.map(\.id)
        _ = empty.unifiedTaskContext(history: thirtyMessages, question: "第27个")
        expect(thirtyMessages == thirtySnapshot && CtripFlightSearchContext.latest(in: thirtyMessages)?.offers.map(\.id) == thirtyIDs &&
               CtripFlightSearchContext.latest(in: thirtyMessages)?.offers == thirtySearch.offers,
               "Reference sampling preserves every original source card, ID and the full ordered local candidate array")
        let sameIDs = (1...30).map { index in offer("MU\(5000 + index)", query: "stored-query-\(index)") }
        let sameIDMessages = [AssistantMessage(role: "assistant", text: "Thirty stored candidates", flightOffers: sameIDs, flightQuery: fullSearchQuery)]
        let sameIDSnapshot = CtripFlightSearchContext.latest(in: sameIDMessages)!
        let sameIDRows = try payload(empty.unifiedTaskContext(history: sameIDMessages, question: "第27个")).offers
        expect(Set(sameIDSnapshot.offers.map(\.id)).count == 1 && sameIDSnapshot.offers.count == 30 &&
               sameIDRows.first(where: { $0["position"] as? Int == 27 })?["flightNumbers"] as? [String] == ["MU5027"] &&
               CtripFlightSearchContext.latest(in: sameIDMessages) == sameIDSnapshot && sameIDMessages.first?.flightOffers == sameIDs,
               "Repeated legacy IDs never collapse candidates or change index-based focus and stored arrays")
        var crowdedSizes: [String: Int] = [:], crowdedContextForWire = ""
        var crowdedMessagesForWire: [AssistantMessage] = []
        var thirtyCrowdedSizes: [String: Int] = [:]
        for (label, value) in families {
            let (vm, fixtures) = viewModel(value)
            let crowdedOffers = (0..<24).map { index -> CtripFlightOffer in
                var item = offer(value, query: value)
                item.title = "MU\(3000 + index) CA1501 CZ3000 HU7000 " + value
                return item
            }
            var crowdedMessages = history(fixtures, offers: crowdedOffers, text: "二十四个完整候选")
            crowdedMessages[crowdedMessages.count - 1].flightQuery = fullSearchQuery
            let originalCrowded = crowdedMessages, originalFixtures = vm.history.records
            let packed = vm.unifiedTaskContext(history: crowdedMessages)
            checkBounds(packed, history: crowdedMessages, label: "Twenty-four candidates plus three tasks: " + label)
            expect(packed != "{}", label + ": crowded references are retained instead of falling back to an empty object")
            let packedPayload = try payload(packed)
            expect(packedPayload.tasks.count == 3 && packedPayload.offers.count == 24,
                   label + ": all three relevant tasks and all twenty-four candidates survive the budget")
            expect(packedPayload.offers.compactMap { $0["position"] as? Int } == Array(1...24),
                   label + ": escaped candidate fields do not change visible card ordinals")
            let object = try JSONSerialization.jsonObject(with: Data(packed.utf8)) as! [String: Any]
            expect((object["flightSearch"] as? [String: Any])?["query"] as? String == fullSearchQuery,
                   label + ": shared date, route, passenger and ending constraints remain complete")
            expect(crowdedMessages == originalCrowded && vm.history.records == originalFixtures,
                   label + ": tighter crowded excerpts never rewrite source cards, queries or task records")
            crowdedSizes[label] = packed.count
            if label == "quotes/slashes/control" { crowdedContextForWire = packed; crowdedMessagesForWire = crowdedMessages }
            var allThirty = crowdedOffers
            for index in 24..<30 {
                var item = offer(value, query: value); item.title = "MU\(3000 + index) CA1501 CZ3000 HU7000 " + value
                allThirty.append(item)
            }
            var sampledMessages = history(fixtures, offers: allThirty, text: "三十个完整候选")
            sampledMessages[sampledMessages.count - 1].flightQuery = fullSearchQuery
            let sampledSnapshot = sampledMessages
            let sampled = vm.unifiedTaskContext(history: sampledMessages, question: "第27个与倒数第三个的行李呢？")
            let sampledPayload = try payload(sampled), sampledPositions = sampledPayload.offers.compactMap { $0["position"] as? Int }
            checkBounds(sampled, history: sampledMessages, label: "Thirty candidates focused plus three tasks: " + label)
            let sampledObject = try JSONSerialization.jsonObject(with: Data(sampled.utf8)) as! [String: Any]
            expect(sampledPayload.tasks.count == 3 && sampledPositions.count == 24 && sampledPositions.contains(27) && sampledPositions.contains(28) &&
                   sampledPositions.contains(1) && sampledPositions.contains(30), label + ": long reference sampling retains both current explicit focuses and anchors")
            expect((sampledObject["flightSearch"] as? [String: Any])?["query"] as? String == fullSearchQuery &&
                   (sampledObject["flightSearch"] as? [String: Any])?["referencesOmitted"] as? Bool == true,
                   label + ": focused samples preserve the complete original 4000-character query and disclose omissions")
            expect(sampledMessages == sampledSnapshot && sampledMessages.last?.flightOffers == allThirty && vm.history.records == originalFixtures,
                   label + ": focus sampling preserves all thirty long cards and three task originals")
            thirtyCrowdedSizes[label] = sampled.count
        }
        let manyCodes = "MU5101 CA1501 CZ3000 HU7000 FM9000"
        let codePayload = try payload(empty.unifiedTaskContext(history: [.init(role: "assistant", text: manyCodes, flightOffers: [offer(manyCodes)])]))
        let codes = codePayload.offers.first?["flightNumbers"] as? [String] ?? []
        expect(codes == ["MU5101", "CA1501", "CZ3000", "HU7000"], "Derived flight identifiers are bounded and come from the original title")

        // Real transactional storage keeps full cards; excerpts belong only to requests.
        let storeURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("fixture-conversations.json")
        let archive = AssistantConversationRecord(id: UUID(), title: "长航班结果", messages: messages, createdAt: at, updatedAt: at, recipient: "offline", draft: "")
        let store = AssistantConversationStore(url: storeURL)
        try store.save([archive], currentConversationID: archive.id)
        let restored = AssistantConversationStore(url: storeURL)
        expect(restored.error.isEmpty && restored.records == [archive], "Real store round-trip preserves complete original cards after reference packing")

        defer { PrivacyConsent.revoke() }
        var wireSizes: [String: Int] = [:]
        for connected in [false, true] {
            let label = connected ? "Responses" : "Custom"
            var settings = AgentSettings(); settings.endpoint = connected ? "https://api.openai.com/v1/chat/completions" : "https://references.invalid/v1/chat/completions"
            PrivacyConsent.grant(settings)
            let router = UnifiedConversationRouter(settings: settings, apiKey: "offline-unused")
            for (name, reference, recent) in [("valid flight history", context, messages), ("large grapheme history", generatedContexts["one enormous grapheme"]!, [.init(role: "user", text: giantGrapheme)]),
                ("twenty-four escaped candidates and three tasks", crowdedContextForWire, crowdedMessagesForWire)] {
                RoutingWireProbe.reset(); let before = RoutingWireProbe.requests.count
                let beginning = "现在的问题 ", ending = " 末尾约束"
                let question = beginning + String(repeating: "问", count: 4000 - beginning.count - ending.count) + ending
                let result = try? await router.route(question: question, history: recent, taskContext: reference)
                expect(result?.mode == .chat && RoutingWireProbe.requests.count == before + 1, label + ": bounded \(name) reaches exactly one request")
                if RoutingWireProbe.requests.count > before {
                    let request = RoutingWireProbe.requests.last!, body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    let turns = body[connected ? "input" : "messages"] as! [[String: Any]]
                    expect(turns.last?["content"] as? String == question, label + ": complete current question and ending constraint survive \(name)")
                    expect(request.httpBody!.count < 600_000, label + ": \(name) cannot expand into an unbounded request body")
                    let guide = connected ? body["instructions"] as? String : turns.first?["content"] as? String
                    expect(guide?.contains("历史节选") == false && guide?.contains("5900") == false, label + ": reference excerpts are data rather than system instructions")
                    wireSizes[label + ":" + name] = request.httpBody!.count
                } else {
                    expect(false, label + ": complete current question and ending constraint survive \(name)")
                    expect(false, label + ": \(name) cannot expand into an unbounded request body")
                    expect(false, label + ": reference excerpts are data rather than system instructions")
                }
            }
            RoutingWireProbe.reset()
            let ordinalRequestCount = RoutingWireProbe.requests.count
            let followup = "第16个航班的行李额度呢？"
            let resolvedQuery = "查询2026-10-26北京到深圳MU2015航班，1名成人经济舱的实际行李额度；未返回则待核实。"
            try RoutingWireProbe.route("flightQuery", request: resolvedQuery)
            let routed = try await router.route(question: followup, history: twentyFourMessages, taskContext: twentyFourContext)
            expect(routed.mode == .flightQuery && routed.request == resolvedQuery && RoutingWireProbe.requests.count == ordinalRequestCount + 1,
                   label + ": a sixteenth-candidate follow-up preserves the resolved query across one routing boundary")
            let ordinalRequest = RoutingWireProbe.requests.last!
            let ordinalBody = try JSONSerialization.jsonObject(with: ordinalRequest.httpBody!) as! [String: Any]
            let ordinalTurns = ordinalBody[connected ? "input" : "messages"] as! [[String: Any]]
            expect(ordinalTurns.last?["content"] as? String == followup,
                   label + ": the ordinal follow-up remains the latest human instruction")
            let ordinalReference = ordinalTurns.dropLast().compactMap { $0["content"] as? String }.joined(separator: "\n")
            expect(ordinalReference.contains("\"position\":16") && ordinalReference.contains("MU2015") && ordinalReference.contains(fullSearchQuery),
                   label + ": routing receives candidate sixteen and the complete newest search conditions")
            for (focusQuestion, expectedPosition) in [("第27个航班的行李额度呢？", 27), ("最后一个呢？", 30), ("倒数第三个呢？", 28)] {
                let sampledReference = empty.unifiedTaskContext(history: thirtyMessages, question: focusQuestion)
                RoutingWireProbe.reset(); let priorFocusedRequests = RoutingWireProbe.requests.count
                try RoutingWireProbe.route("clarify", message: "请确认要查询的行李政策；尚未执行。")
                let focusedRoute = try await router.route(question: focusQuestion, history: thirtyMessages, taskContext: sampledReference)
                expect(focusedRoute.mode == .clarify && RoutingWireProbe.requests.count == priorFocusedRequests + 1,
                       label + ": focused reference data does not grant execution authorization")
                let request = RoutingWireProbe.requests.last!, body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let turns = body[connected ? "input" : "messages"] as! [[String: Any]]
                let refs = turns.dropLast().compactMap { $0["content"] as? String }.joined(separator: "\n")
                expect(turns.last?["content"] as? String == focusQuestion && refs.contains("\"position\":\(expectedPosition)") &&
                       refs.contains("MU\(4000 + expectedPosition)") && refs.contains(fullSearchQuery) && refs.contains("referencesOmitted"),
                       label + ": the actual bounded client request receives the current focus and omission metadata")
            }
        }
        let result: [String: Any] = ["checks": checks, "failures": failures, "originalCaseContextCharacters": context.count,
            "twentyFourCandidateContextCharacters": crowdedSizes, "thirtyCandidateContextCharacters": thirtyCrowdedSizes,
            "thirtyCandidateFocusPositions": focusPositions, "wireBytes": wireSizes,
            "scope": "Actual Ctrip decoder/parser, transactional store, routing input and both model clients; complete extracted context method with synthetic task containers; only HTTP loaders replaced. Ordinal-route responses are injected, not model-quality acceptance. No network/model/phone."]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: bytes, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
