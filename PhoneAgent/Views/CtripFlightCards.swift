import Foundation
import SwiftUI

/// Presentation uses the human turn, never the provider's normalized query.
enum CtripFlightCardPresentationPolicy {
    static func showsSortExplanation(messageID: UUID, messages: [AssistantMessage]) -> Bool {
        guard let reply = messages.firstIndex(where: { $0.id == messageID }), messages[reply].role == "assistant",
              let human = messages[..<reply].lastIndex(where: { $0.role == "user" || $0.role == "human" }),
              messages[..<human].contains(where: { $0.role == "assistant" && ($0.flightQuery != nil || $0.flightOffers != nil) }) else { return false }
        return explicitlyChangesSorting(messages[human].text)
    }

    static func explicitlyChangesSorting(_ question: String) -> Bool {
        let text = question.lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard !text.isEmpty else { return false }
        // A request to keep ordering or hide its explanation takes precedence.
        let suppress = #"(?:不要|不用|无需|不必|别|不需要|不)(?:再)?(?:解释|说明|展示|显示|讲解)[^，,。；;！？!?\n]{0,8}(?:排序|怎么排)|(?:排序|排序规则|排序说明)(?:不用|无需|不必|不要)(?:再)?(?:解释|说明|展示|显示)|(?:不要|不用|无需|不必|别|不需要|不)(?:再)?(?:改|改变|改动|修改|调整|更改|变动)(?:变)?(?:当前|现有|原来|这个|本次|任何|航班)*排序|(?:保持|保留)(?:当前|现有|原来)?排序(?:不变)?|排序(?:保持)?不变|(?:没有|未|无)(?:指定)?排序偏好"#
        guard text.range(of: suppress, options: .regularExpression) == nil else { return false }
        let positive = #"(?:价格|票价|低价|便宜|最便宜|总耗时|全程(?:总)?时长|耗时|用时|时间最短|早飞|早到|直飞|少中转|中转次数少|最少中转|出发时段|到达时段|上午出发|下午出发|晚上出发)(?:更)?优先|(?:按|按照|先看|先比)(?:同口径)?(?:价格|票价|总耗时|全程(?:总)?时长|耗时|用时|起飞时间|出发时间|到达时间)(?:(?:从|由)?低到高|(?:从|由)?高到低|升序|降序)?(?:排|排序)|(?:改成|改为|改回|换成|换为|调整为)(?:按)?(?:默认排序|默认规则|价格最低|票价最低|最便宜|耗时最短|总耗时最短|最早出发|最早到达|中转最少)|(?:重新排序|调整排序|更改排序|修改排序|改变排序)|(?:最便宜|便宜|低价|最快|耗时短|总耗时短|早飞|早到|起飞早|最早出发|最早到达|少中转)(?:的)?(?:排|放)(?:在)?(?:最前|前面|第一)"#
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;！？!?\n"))
        return clauses.contains { clause in
            guard let range = clause.range(of: positive, options: .regularExpression) else { return false }
            let before = String(clause[..<range.lowerBound])
            return before.range(of: #"(?:不要|不用|无需|不必|别|不需要|不是|并非|不想|不)(?:再)?(?:按|按照|改成|改为|优先考虑)?$"#, options: .regularExpression) == nil
        }
    }

    static func shortSortExplanation(_ source: String) -> String {
        if source.contains("未按金额排序") { return "报价口径不同或未明确，暂未按金额排序。" }
        let first = source.replacingOccurrences(of: "排序：", with: "").components(separatedBy: " → ").first ?? ""
        let labels = ["同口径报价低": "价格", "总耗时短": "全程总时长", "中转次数少": "少中转", "起飞早": "早飞", "到达早": "早到", "直飞优先": "直飞"]
        if let label = labels[first] { return "已按" + label + "优先调整。" }
        return "已按你的排序偏好调整。"
    }

    static func preferredHeading(_ offer: CtripFlightOffer, recommendation: CtripFlightRecommendation) -> String {
        switch offer.selectionStatus {
        case .satisfied:
            return recommendation.preferredOfferID == nil && !recommendation.commonNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "可选方案" : "优先方案"
        case .insufficientInformation: return "待核实方案"
        case .doesNotMeet: return "不符合条件的方案"
        }
    }

    static func isTransfer(_ offer: CtripFlightOffer) -> Bool {
        offer.itinerarySegments.count > 1 || offer.cardSegments.count > 1 ||
            CtripFlightParser.flightNumbers(in: offer.title).count > 1 || offer.field("航程类型") == "中转"
    }

    private static func primaryDuration(_ value: String) -> String? {
        let primary = value.components(separatedBy: CharacterSet(charactersIn: "（(")).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard primary.range(of: #"^(?:约)?(?:\d{1,4}\s*(?:天|小时|分钟|分|h|min|m)\s*)+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return primary
    }

    /// Only the returned whole-journey duration can carry an including-wait label.
    /// Flight durations and endpoint clock differences are never substitutes.
    private static func returnedWholeDurations(_ offer: CtripFlightOffer) -> Set<String> {
        Set(offer.details.components(separatedBy: .newlines).compactMap { line -> String? in
            let value = CtripFlightParser.value("总耗时", in: line).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
    }

    static func wholeJourneyDuration(_ offer: CtripFlightOffer) -> String {
        let returned = returnedWholeDurations(offer)
        guard returned.count == 1, let value = returned.first,
              !["不含等待", "不含中转等待", "不含转机等待", "未含等待", "仅飞行", "纯飞行", "飞行时间合计"].contains(where: { value.contains($0) }),
              let duration = primaryDuration(value) else { return "待核实" }
        return duration
    }

    static func summaryMetadata(_ offer: CtripFlightOffer) -> [String] {
        guard isTransfer(offer) else { return offer.cardMetadata }
        let totals = Set(returnedWholeDurations(offer).compactMap(primaryDuration))
        return offer.cardMetadata.filter { value in
            guard let duration = primaryDuration(value) else { return true }
            return !totals.contains(duration)
        }
    }
}

struct CtripFlightCards: View {
    let offers: [CtripFlightOffer]
    var recommendation: CtripFlightRecommendation? = nil
    var showsSortExplanation = false
    let onBook: (CtripFlightOffer) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var timeSize: CGFloat = 29
    @State private var additionalCount = 0

    var body: some View {
        let ordered = CtripFlightParser.displayOrder("", representedBy: offers)
        let preferred = ordered.first
        let remaining = Array(ordered.dropFirst())
        let summary = recommendation ?? CtripFlightParser.recommendation("", representedBy: offers)
        VStack(spacing: 12) {
            if let preferred {
                if showsSortExplanation {
                    Text(CtripFlightCardPresentationPolicy.shortSortExplanation(summary.sortDescription))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("flight.sortDescription")
                }
                Text(CtripFlightCardPresentationPolicy.preferredHeading(preferred, recommendation: summary)).font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                card(preferred)
            }
            if !remaining.isEmpty {
                if additionalCount > 0 {
                    Text("其他方案 · \(min(additionalCount, remaining.count)) 个").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(remaining.prefix(additionalCount).enumerated()), id: \.offset) { item in card(item.element) }
                }
                if additionalCount < remaining.count {
                    Button {
                        additionalCount = additionalCount == 0 ? min(6, remaining.count) : remaining.count
                    } label: {
                        moreLabel(remainingCount: remaining.count)
                            .font(.subheadline.weight(.medium)).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("flight.more")
                }
            }
            if !summary.commonNotes.isEmpty {
                Text(summary.commonNotes).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("flight.commonNotes")
            }
            if let latest = offers.map(\.queriedAt).max() {
                Text("携程查询 · " + latest.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(offers.allSatisfy(\.isSchedule) ?
                 "以上为时刻参考，票价、余票及实际起降安排待查。请在携程核对机场、人数和舱位。" :
                 "价格与余票以携程实时页面为准。请在携程核对机场、人数和舱位后选票。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func moreLabel(remainingCount: Int) -> some View {
        let title = additionalCount == 0 ? "更多方案" : "查看剩余全部方案"
        let count = additionalCount == 0 ? "\(remainingCount) 个" : "剩余 \(remainingCount - additionalCount) 个"
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                }
                Text(count).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 12) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(count).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
            }
        }
    }

    private func visibleIssues(_ offer: CtripFlightOffer) -> [String] {
        var result: [String] = []
        for value in offer.selectionIssues + offer.cardWarnings where !result.contains(value) { result.append(value) }
        return result
    }
    private func card(_ offer: CtripFlightOffer) -> some View {
        let status = offer.selectionStatus
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image("Brand-ctrip").resizable().scaledToFit().frame(width: 24, height: 24)
                Text(offer.cardTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Label(offer.isSchedule ? "时刻参考 · 尚未核价" : "携程查询报价", systemImage: offer.isSchedule ? "clock" : "tag")
                .font(.caption).foregroundStyle(offer.isSchedule ? .secondary : .primary)
                .accessibilityIdentifier(offer.isSchedule ? "flight.schedule" : "flight.quote")
            if status != .satisfied {
                Label(status == .doesNotMeet ? "不符合本次条件" : "条件信息待核实",
                      systemImage: status == .doesNotMeet ? "exclamationmark.triangle" : "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flight.selectionStatus")
            }
            if CtripFlightCardPresentationPolicy.isTransfer(offer) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("全程总时长（含中转等待）").font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(CtripFlightCardPresentationPolicy.wholeJourneyDuration(offer))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("flight.totalDuration")
            }
            itinerary(offer)
            if !offer.transferAirport.isEmpty {
                Label(offer.transferAirport == "中转机场" ? "中转机场待核实" : "经 " + offer.transferAirport, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let metadata = CtripFlightCardPresentationPolicy.summaryMetadata(offer)
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(visibleIssues(offer).enumerated()), id: \.offset) { item in
                Text(item.element).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !offer.cardSupplement.isEmpty {
                DisclosureGroup("更多信息") {
                    Text(offer.cardSupplement).font(.footnote).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }.font(.subheadline).accessibilityIdentifier("flight.details")
            }
            priceAndBooking(offer)
            if offer.preferredNativeFlightSelectionURL != nil || offer.nativeFlightSelectionLookupQuery != nil {
                Text(offer.preferredNativeFlightSelectionURL != nil ? "打开这班航班的选价页，票价与舱位以携程页面为准" : "先补查这班航班的信息，再尝试打开它的选价页")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("flight.handoffScope")
            }
        }.padding(16).background(AgentPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(AgentPalette.ink.opacity(offer.isSchedule ? 0.25 : 0.10),
                style: StrokeStyle(lineWidth: 1, dash: offer.isSchedule ? [5, 4] : [])))
            .accessibilityElement(children: .contain).accessibilityIdentifier("flight.card")
    }

    @ViewBuilder private func itinerary(_ offer: CtripFlightOffer) -> some View {
        let segments = offer.itinerarySegments
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(segments.enumerated()), id: \.offset) { item in
                    if item.offset > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 10) {
                        if segments.count > 1 || CtripFlightParser.flightNumbers(in: offer.title).count > 1 {
                            Text(segmentHeading(item.element, position: item.offset + 1))
                                .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        route(departure: item.element.departure, arrival: item.element.arrival)
                        let metadata = [item.element.aircraft, item.element.duration].filter { !$0.isEmpty }
                        if !metadata.isEmpty {
                            Text(metadata.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("flight.segment")
                }
            }
        } else if !offer.cardSegments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("航段信息待核实").font(.caption).foregroundStyle(.secondary)
                Text(dateText(offer.leg(departure: true).date)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(offer.cardSegments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(segment.title).font(.subheadline.weight(.semibold))
                        Text(segment.text).font(.subheadline).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.accessibilityIdentifier("flight.legacyItinerary")
        } else if CtripFlightParser.flightNumbers(in: offer.title).count > 1,
                  !CtripFlightParser.value("中转行程", in: offer.details).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("中转行程待核实").font(.caption).foregroundStyle(.secondary)
                Text(dateText(offer.leg(departure: true).date)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CtripFlightParser.value("中转行程", in: offer.details)).font(.subheadline)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("flight.legacyItinerary")
        } else {
            route(departure: offer.leg(departure: true), arrival: offer.leg(departure: false))
        }
    }
    private func segmentHeading(_ segment: CtripFlightSegment, position: Int) -> String {
        let title = segment.title.isEmpty ? "航段 \(position)" : segment.title
        guard !segment.code.isEmpty else { return title + " · 航班号待核实" }
        return title.contains(segment.code) ? title : title + " · " + segment.code
    }
    @ViewBuilder private func route(departure: CtripFlightOffer.Leg, arrival: CtripFlightOffer.Leg) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                endpoint(departure, departure: true, trailing: false, showRole: true)
                Image(systemName: "airplane").rotationEffect(.degrees(90)).font(.title3).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                endpoint(arrival, departure: false, trailing: false, showRole: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                endpoint(departure, departure: true, trailing: false)
                Image(systemName: "airplane").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
                endpoint(arrival, departure: false, trailing: true)
            }
        }
    }
    private func endpoint(_ leg: CtripFlightOffer.Leg, departure: Bool, trailing: Bool, showRole: Bool = false) -> some View {
        let time = leg.time.isEmpty || leg.time.contains("待核对") ? "待核实" : leg.time
        let airport = leg.airport.isEmpty ? (departure ? "出发机场待核实" : "到达机场待核实") : leg.airport.replacingOccurrences(of: "待核对", with: "待核实")
        let date = dateText(leg.date)
        let role = departure ? "出发" : "到达"
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            if showRole { Text(role).font(.caption).foregroundStyle(.secondary) }
            Text(time).font(.system(size: timeSize, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(airport).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text(date).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.multilineTextAlignment(trailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(role + "，" + time + "，" + airport + "，" + date)
            .accessibilityIdentifier(departure ? "flight.departure" : "flight.arrival")
    }
    private func dateText(_ value: String) -> String {
        guard !value.isEmpty else { return "日期待核实" }
        if ["次日", "翌日", "隔天"].contains(value) { return value + " · 日期待核实" }
        return value.replacingOccurrences(of: "待核对", with: "待核实")
    }

    @ViewBuilder private func priceAndBooking(_ offer: CtripFlightOffer) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedPriceAndBooking(offer)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    price(offer).fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: 8)
                    bookingButton(offer).fixedSize(horizontal: true, vertical: true)
                }
                stackedPriceAndBooking(offer)
            }
        }
    }
    private func stackedPriceAndBooking(_ offer: CtripFlightOffer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            price(offer).frame(maxWidth: .infinity, alignment: .leading)
            bookingButton(offer, fullWidth: true)
        }
    }
    private func price(_ offer: CtripFlightOffer) -> some View {
        Text(offer.cardPrice).font(offer.isSchedule ? .subheadline : .title3.weight(.semibold)).monospacedDigit()
            .foregroundStyle(offer.isSchedule ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("flight.price")
    }
    private func bookingButton(_ offer: CtripFlightOffer, fullWidth: Bool = false) -> some View {
        Button { onBook(offer) } label: {
            Text(offer.bookingButtonTitle).font(.subheadline.bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
                .foregroundStyle(offer.isSchedule ? Color.primary : Color.white)
                .background(offer.isSchedule ? Color.clear : Color.blue, in: Capsule())
                .overlay(Capsule().stroke(offer.isSchedule ? Color.secondary.opacity(0.5) : Color.clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(offer.bookingButtonTitle + "，" + offer.cardTitle)
            .accessibilityIdentifier("flight.book")
    }
}


/// A flight response without complete cards stays compact until the user asks for its source.
struct CtripFlightEmptyResult: View {
    let text: String
    @State private var showsOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这次未返回可展示的完整航班方案。")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("flight.emptyResult")
            DisclosureGroup("查看原始结果", isExpanded: $showsOriginal) {
                Text(text).font(.footnote).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }.font(.subheadline).accessibilityIdentifier("flight.originalResult")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
