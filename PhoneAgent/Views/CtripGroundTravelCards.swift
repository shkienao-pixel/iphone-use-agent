import SwiftUI

/// Read-only results. The host owns all opening and error handling; this view
/// cannot turn a lookup into an order or claim a particular page was reached.
struct CtripGroundTravelCards: View {
    let offers: [CtripGroundTravelOffer]
    let onOpen: (CtripGroundTravelOffer) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            ForEach(offers) { offer in card(offer) }
        }
    }

    private func card(_ offer: CtripGroundTravelOffer) -> some View {
        let blue = Color(red: 0.05, green: 0.46, blue: 0.84)
        let name = offer.number.isEmpty ? (offer.mode == .train ? "火车班次" : "汽车班次") : offer.number
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image("Brand-ctrip").resizable().scaledToFit().frame(width: 20, height: 20)
                Text(name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: offer.mode == .train ? "tram.fill" : "bus.fill")
                    .font(.subheadline).opacity(0.7).accessibilityHidden(true)
            }.foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 10) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        endpoint("出发", station: offer.departureStation, time: offer.departureTime, date: offer.departureDate)
                        endpoint("到达", station: offer.arrivalStation, time: offer.arrivalTime, date: offer.arrivalDate)
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        endpoint("出发", station: offer.departureStation, time: offer.departureTime, date: offer.departureDate)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 26).accessibilityHidden(true)
                        Spacer(minLength: 4)
                        endpoint("到达", station: offer.arrivalStation, time: offer.arrivalTime, date: offer.arrivalDate, trailing: true)
                    }
                }
                if !offer.seat.isEmpty {
                    Text("席别：" + offer.seat).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !offer.availability.isEmpty {
                    Text("余票：" + offer.availability).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
    private func endpoint(_ role: String, station: String, time: String, date: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 3) {
            Text(date.isEmpty ? "日期待核实" : date).font(.caption2).foregroundStyle(.secondary)
            Text(time.isEmpty ? "时间待核实" : time).font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(station).font(.caption).fixedSize(horizontal: false, vertical: true)
        }.multilineTextAlignment(trailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(role + "，" + (date.isEmpty ? "日期待核实" : date) + "，" + (time.isEmpty ? "时间待核实" : time) + "，" + station)
    }
    private func price(_ offer: CtripGroundTravelOffer) -> some View {
        Text(offer.price.isEmpty ? "票价待查" : offer.price).font(.headline).monospacedDigit()
            .foregroundStyle(offer.price.isEmpty ? Color.secondary : Color(red: 0.91, green: 0.42, blue: 0.08))
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("ground.price")
    }
    private func button(_ offer: CtripGroundTravelOffer) -> some View {
        let label = offer.verifiedURL == nil ? "打开携程查询" : "查看这班"
        return Button { onOpen(offer) } label: {
            Text(label).font(.subheadline.bold()).multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
                .foregroundStyle(.white).background(Color.blue, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("ground.open")
            .accessibilityLabel(label + "，" + (offer.number.isEmpty ? (offer.mode == .train ? "火车" : "汽车") : offer.number))
    }
}
