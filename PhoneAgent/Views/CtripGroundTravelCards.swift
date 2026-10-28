import SwiftUI

/// Read-only results. The host owns all opening and error handling; this view
/// cannot turn a lookup into an order or claim a particular page was reached.
struct CtripGroundTravelResult: View {
    let text: String
    let mode: CtripGroundTravelMode
    let onOpen: (URL?) -> Void
    @State private var showsOriginal = false

    var body: some View {
        let entries = CtripGroundTravelParser.displayEntries(text: text, mode: mode)
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .train ? "火车票查询结果" : "汽车票查询结果")
                .font(.headline).accessibilityIdentifier("ground.result.title")
            if let source = text.components(separatedBy: .newlines).first,
               source.hasPrefix("来源：") || source.hasPrefix("来源:") {
                Text(source).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("暂未识别到可展示的班次信息", systemImage: "info.circle")
                        .font(.subheadline.weight(.medium))
                    Text("请查看原始回复中的查询结果或原因。缺少信息不代表没有余票。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("打开携程查询") { onOpen(nil) }.frame(minHeight: 44)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("ground.result.empty")
                SelaMarkdownText(text: text)
            } else {
                Text("已整理 \(entries.count) 条返回信息；请核对实际站点与查询条件，完整说明见原始回复。")
                    .font(.caption).foregroundStyle(.secondary)
                CtripGroundTravelCards(entries: entries) { onOpen($0.verifiedURL) }
                Text("打开携程将进入普通查询页面，尚未选定班次。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看原始回复", isExpanded: $showsOriginal) {
                    SelaMarkdownText(text: text).padding(.top, 8)
                }.font(.subheadline).accessibilityIdentifier("ground.result.original")
            }
        }.accessibilityIdentifier("ground.result")
    }
}

struct CtripGroundTravelCards: View {
    let entries: [CtripGroundTravelDisplayEntry]
    let onOpen: (CtripGroundTravelDisplayEntry) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in card(entry, index: index) }
        }
    }

    private func card(_ offer: CtripGroundTravelDisplayEntry, index: Int) -> some View {
        let blue = Color(red: 0.05, green: 0.46, blue: 0.84)
        let name = offer.number.isEmpty ? "查询结果 \(index + 1)" : offer.number
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image("Brand-ctrip").resizable().scaledToFit().frame(width: 20, height: 20)
                Text(name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: offer.mode == .train ? "tram.fill" : "bus.fill")
                    .font(.subheadline).opacity(0.7).accessibilityHidden(true)
            }.foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 10) {
                if !offer.isComplete {
                    Label("信息不完整 · 请核对缺失项", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ground.incomplete")
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        endpoint("出发", station: offer.departureStation, city: offer.departureCity, time: offer.departureTime, date: offer.departureDate)
                        endpoint("到达", station: offer.arrivalStation, city: offer.arrivalCity, time: offer.arrivalTime, date: offer.arrivalDate)
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        endpoint("出发", station: offer.departureStation, city: offer.departureCity, time: offer.departureTime, date: offer.departureDate)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 26).accessibilityHidden(true)
                        Spacer(minLength: 4)
                        endpoint("到达", station: offer.arrivalStation, city: offer.arrivalCity, time: offer.arrivalTime, date: offer.arrivalDate, trailing: true)
                    }
                }
                if !offer.seat.isEmpty {
                    Text("席别：" + offer.seat).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("余票：" + (offer.availability.isEmpty ? "未提供" : offer.availability))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !offer.duration.isEmpty {
                    Text("历时：" + offer.duration).font(.caption).foregroundStyle(.secondary)
                }
                if !offer.serviceFee.isEmpty {
                    Text("在线服务费：" + offer.serviceFee).font(.caption).foregroundStyle(.secondary)
                }
                Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.gray.opacity(0.3)).frame(height: 1)
                    .padding(.horizontal, 15).frame(height: 16)
                    .overlay(alignment: .leading) { Circle().fill(blue).frame(width: 16, height: 16).offset(x: -8) }
                    .overlay(alignment: .trailing) { Circle().fill(blue).frame(width: 16, height: 16).offset(x: 8) }
                    .padding(.horizontal, -16).accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        price(offer); Spacer(minLength: 8); button(offer)
                    }
                    VStack(alignment: .leading, spacing: 10) { price(offer); button(offer) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12).padding(.bottom, 12)
        }.background(blue).clipShape(RoundedRectangle(cornerRadius: 8))
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ground.card")
    }
    private func endpoint(_ role: String, station: String, city: String, time: String, date: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 3) {
            Text(date.isEmpty ? "日期待核实" : date).font(.caption2).foregroundStyle(.secondary)
            Text(time.isEmpty ? "时间待核实" : time)
                .font(time.isEmpty ? .caption : .system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(time.isEmpty ? nil : 1).minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            if !city.isEmpty {
                Text(role + "城市：" + city).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text(station.isEmpty ? role + "站：未提供" : station)
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }.multilineTextAlignment(trailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(role + "，" + (date.isEmpty ? "日期待核实" : date) + "，" + (time.isEmpty ? "时间待核实" : time) + "，" + (city.isEmpty ? "" : city + "，") + (station.isEmpty ? role + "站未提供" : station))
    }
    private func price(_ offer: CtripGroundTravelDisplayEntry) -> some View {
        Text(offer.price.isEmpty ? "票价待查" : offer.price).font(.headline).monospacedDigit()
            .foregroundStyle(offer.price.isEmpty ? Color.secondary : Color(red: 0.91, green: 0.42, blue: 0.08))
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("ground.price")
    }
    private func button(_ offer: CtripGroundTravelDisplayEntry) -> some View {
        let label = offer.verifiedURL == nil ? "打开携程查询" : "查看这班"
        return Button { onOpen(offer) } label: {
            Text(label).font(.subheadline.bold()).multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
                .foregroundStyle(.white).background(Color.blue, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("ground.open")
            .accessibilityLabel(label + "，" + (offer.number.isEmpty ? (offer.mode == .train ? "火车" : "汽车") : offer.number))
    }
}
