import SwiftUI

struct NativeTaskResultCards: View {
    let results: [NativeTaskResult]
    @State private var expanded = false
    private var displayed: [NativeTaskResult] {
        let ordered = NativeTaskResult.displayOrder(results)
        return expanded ? ordered : Array(ordered.prefix(3))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(displayed) { NativeTaskResultCard(result: $0) }
            if results.count > 3 {
                Button(expanded ? "收起结果" : "查看全部 \(results.count) 项结果") { expanded.toggle() }
                    .font(.subheadline).accessibilityIdentifier("native.results.expand")
            }
        }
    }
}

private struct NativeTaskResultCard: View {
    let result: NativeTaskResult
    private var name: String {
        switch result.app {
        case .alarm: "闹钟"
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .notes: "备忘录"
        case .health: "健康"
        case .contacts: "通讯录"
        case .photos: "照片"
        case .music: "音乐"
        case .location: "位置"
        case .content: "本机内容"
        }
    }
    private var tint: Color {
        switch result.app {
        case .alarm: .orange
        case .calendar: .red
        case .reminders, .location: .blue
        case .notes: .yellow
        case .health: .pink
        case .contacts: .gray
        case .photos: .purple
        case .music: .red
        case .content: AgentPalette.secondaryText
        }
    }
    private var asset: String? {
        switch result.app {
        case .location: nil
        case .content: "Brand-Sela"
        default: "Native-" + result.app.rawValue
        }
    }
    private var clockTime: String? {
        guard let date = result.date, result.operation == "alarm_create" else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "H:mm"; return formatter.string(from: date)
    }
    private func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = result.app == .health ? "yyyy年M月d日" : (result.app == .alarm ? "M月d日 EEEE" : "M月d日 EEEE HH:mm")
        return formatter.string(from: date)
    }
    private var detail: String {
        if result.app == .health {
            let bounds = result.detail.components(separatedBy: " — ").compactMap(NativeTaskResult.parseDate)
            if bounds.count == 2 { return day(bounds[0]) + " 至 " + day(bounds[1]) }
        }
        return result.detail
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let asset { Image(asset).resizable().scaledToFit().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true) }
                else { Image(systemName: "location.fill").font(.title3).foregroundStyle(tint).frame(width: 30, height: 30).accessibilityHidden(true) }
                Text(name).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("任务结果").font(.caption).foregroundStyle(.secondary)
            }
            if let clockTime {
                HStack(alignment: .firstTextBaseline) {
                    Text(clockTime).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                    Spacer(minLength: 8)
                    Label(result.value, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(tint)
                }
                Text(result.title).font(.headline)
            } else {
                Text(result.title).font(.headline)
                Text(result.value).font(.title3.weight(.semibold)).foregroundStyle(tint)
            }
            if let date = result.date, result.app != .health { Text(day(date)).font(.subheadline).foregroundStyle(.secondary) }
            if let end = result.endDate { Text("至 " + day(end)).font(.subheadline).foregroundStyle(.secondary) }
            if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            if !result.notice.isEmpty { Text(result.notice).font(.caption).foregroundStyle(.secondary) }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.result." + result.app.rawValue + "." + result.id)
    }
}
