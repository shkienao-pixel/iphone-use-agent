import SwiftUI

struct CtripFlightCards: View {
    let offers: [CtripFlightOffer]
    var recommendation: CtripFlightRecommendation? = nil
    let onBook: (CtripFlightOffer) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var timeSize: CGFloat = 29
    @State private var additionalCount = 0

    var body: some View {
        let ordered = CtripFlightParser.displayOrder("", representedBy: offers)
        let preferred = ordered.first
        let remaining = Array(ordered.dropFirst())
        let summary = recommendation ?? CtripFlightParser.recommendation("", representedBy: offers)
        let rule = summary.sortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 12) {
            if let preferred {
                Text(rule.isEmpty ? "排序：按当前查询返回顺序" : rule).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("flight.sortDescription")
                Text(preferredHeading(preferred)).font(.subheadline.weight(.semibold))
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
                 "以上为时刻参考，票价、余票及实际起降安排待查。点击会复制参考航班并打开携程 App 查价。" : offers.allSatisfy { $0.flightSpecificBookingURL != nil } ?
                 "价格与余票以携程实时页面为准。预订将在携程 App 内继续，请核对航班与舱位。" :
                 "未提供航班付款直达入口。点击按钮会复制所选航班信息并打开携程 App，方便继续选票；价格与余票以携程为准。")
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

    private func preferredHeading(_ offer: CtripFlightOffer) -> String {
        switch offer.selectionStatus {
        case .satisfied: return "优先方案"
        case .insufficientInformation: return "待核实方案"
        case .doesNotMeet: return "不符合条件的方案"
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
            itinerary(offer)
            if !offer.transferAirport.isEmpty {
                Label(offer.transferAirport == "中转机场" ? "中转机场待核实" : "经 " + offer.transferAirport, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !offer.cardMetadata.isEmpty {
                Text(offer.cardMetadata.joined(separator: " · "))
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
