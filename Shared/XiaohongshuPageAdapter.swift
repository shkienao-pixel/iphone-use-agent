import Foundation

struct XiaohongshuPixel {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    var isRed: Bool { alpha > 0.8 && red > 0.55 && red > green * 1.35 && red > blue * 1.2 }
    var isPinkTint: Bool { alpha > 0.8 && red > 0.85 && green > 0.55 && blue > 0.55 && green < 0.96 && blue < 0.98 && red > green * 1.035 && red > blue * 1.015 }
}

struct XiaohongshuSelectionEvidence: Codable, Equatable {
    enum Method: String, Codable { case explicitSelectedText, redTextAndUnderline, redTextAndFilledChip, neutralTextAndRedUnderline, nativeLatestContrastChip }
    var elementID: String
    var label: String
    var method: Method
    var capturedAt: Date
    var screenshotSHA256: String?
    var redTextSamples = 0
    var redUnderlineSamples = 0
    var pinkChipSamples = 0
    // Optional fields preserve existing saved documents. These belong to the
    // current screenshot; label presence alone never supplies these values.
    var neutralTextSamples: Int? = nil
    var underlineFraction: Double? = nil
    var peerElementID: String? = nil
    var textLuminance: Double? = nil
    var peerTextLuminance: Double? = nil
    var chipBackgroundSamples: Int? = nil
    var chipContrast: Double? = nil
}

/// Deterministic UI evidence only. A visible sort/filter option is not selected
/// until an explicit marker or current-image red text+underline proves it.
enum XiaohongshuPageAdapter {
    struct NativeLatestLayout {
        var all: PhoneUIElement
        var top: PhoneUIElement
        var latest: PhoneUIElement
        var contentBeginsAt: Double { max(top.rect.y + top.rect.height, latest.rect.y + latest.rect.height) + 0.012 }
    }
    /// All is a CONTENT CATEGORY. Top is only a contrast peer, not an alias
    /// for general/relevance. Both chips must actually be present in one row.
    static func nativeLatestLayout(in snapshot: PhoneUISnapshot) -> NativeLatestLayout? {
        guard !snapshot.blockingOverlay else { return nil }
        let ocr = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid }
        func unique(_ label: String, _ region: (PhoneUIRect) -> Bool) -> PhoneUIElement? {
            let values = ocr.filter { baseLabel($0.label) == label && region($0.rect) }
            return values.count == 1 ? values[0] : nil
        }
        guard let all = unique("all", { (0.10...0.25).contains($0.centerY) }),
              let top = unique("top", { (0.17...0.85).contains($0.centerY) }),
              let latest = unique("latest", { (0.17...0.85).contains($0.centerY) }),
              all.rect.centerX < 0.20, top.rect.centerX < latest.rect.centerX,
              top.rect.width < 0.25, latest.rect.width < 0.25,
              top.rect.height < 0.045, latest.rect.height < 0.045,
              abs(top.rect.centerY - latest.rect.centerY) < 0.018,
              min(top.rect.y, latest.rect.y) > all.rect.y + all.rect.height + 0.012 else { return nil }
        let peers = ocr.filter { ["users", "products", "images"].contains(baseLabel($0.label)) && abs($0.rect.centerY - all.rect.centerY) < 0.025 }
        guard Set(peers.map { baseLabel($0.label) }).count >= 2,
              Set(peers.map { baseLabel($0.label) }).count == peers.count else { return nil }
        return .init(all: all, top: top, latest: latest)
    }
    static func normalized(_ text: String) -> String { PhonePageAdapters.normalized(text) }
    static func baseLabel(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["（已选）", "(已选)", " 已选", " ✓", " ✔", " (selected)", " (Selected)", " selected", " Selected"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["已选：", "已选:", "Selected: ", "selected: ", "排序：", "排序:", "Sort: ", "Sort by: ", "sort: "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized(value)
    }
    static func sortKey(_ text: String) -> String {
        let base = baseLabel(text)
        let aliases: [String: String] = ["综合": "general", "默认": "general", "general": "general", "relevance": "general", "best": "general", "recommended": "general",
            "最新": "latest", "最新发布": "latest", "latest": "latest", "newest": "latest", "most recent": "latest",
            "最热": "popular", "最热笔记": "popular", "热门": "popular", "popular": "popular", "most popular": "popular",
            "最多点赞": "most_liked", "most liked": "most_liked", "most likes": "most_liked",
            "最多收藏": "most_saved", "most saved": "most_saved", "most favorites": "most_saved",
            "主页顺序": "profile_order", "profile order": "profile_order"]
        return aliases[base] ?? base
    }
    static func identity(in snapshot: PhoneUISnapshot, noteOpenedFromResults: Bool = false) -> PhonePageIdentity? {
        guard !snapshot.blockingOverlay else { return nil }
        let elements = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid }
        func matches(_ labels: [String], _ region: (PhoneUIRect) -> Bool = { _ in true }) -> [PhoneUIElement] {
            let keys = Set(labels.map(baseLabel))
            return elements.filter { keys.contains(baseLabel($0.label)) && region($0.rect) }
        }
        func one(_ labels: [String], _ region: (PhoneUIRect) -> Bool = { _ in true }) -> PhoneUIElement? {
            let result = matches(labels, region); return result.count == 1 ? result[0] : nil
        }
        let top: (PhoneUIRect) -> Bool = { $0.centerY < 0.18 }
        let brand = one(["小红书", "xiaohongshu", "rednote"], top)
        let copy = one(["复制链接", "复制笔记链接", "copy link", "copy note link"], { $0.centerY > 0.32 })
        let cancel = one(["取消", "cancel", "关闭", "close"], { $0.centerY > 0.42 })
        let shareAnchors = matches(["分享至", "分享到", "分享给", "share to", "share with", "分享", "share", "微信", "wechat", "朋友圈", "moments", "保存图片", "save image"], { $0.centerY > 0.25 })
        if let copy, let cancel, !shareAnchors.isEmpty {
            return .init(scene: "xiaohongshu.share", evidence: [copy.id, cancel.id] + shareAnchors.map(\.id))
        }
        let tabs = matches(["综合", "general", "best", "relevance", "all", "用户", "users", "商品", "goods", "shopping", "products", "images", "视频", "videos", "笔记", "notes"], { (0.12...0.35).contains($0.centerY) })
        let filter = one(["筛选", "筛选中", "filter", "filters"], { $0.centerY < 0.4 })
        let search = one(["搜索", "search"], top), topCancel = one(["取消", "cancel"], top)
        let history = one(["历史记录", "搜索历史", "recent searches", "search history"], { (0.18...0.65).contains($0.centerY) })
        let trending = one(["猜你想搜", "大家都在搜", "热门搜索", "trending searches", "trending", "recommended searches"], { (0.18...0.85).contains($0.centerY) })
        if let search, let topCancel, let history, brand != nil || trending != nil {
            return .init(scene: "xiaohongshu.search", evidence: [search.id, topCancel.id, history.id] + [brand?.id, trending?.id].compactMap { $0 })
        }
        let filterDone = one(["收起", "完成", "应用", "确认", "done", "apply", "confirm"], { $0.centerY > 0.25 })
        let reset = one(["重置", "reset"], { $0.centerY > 0.25 })
        let filterGroups = matches(["排序依据", "排序", "sort by", "sort", "笔记类型", "note type", "发布时间", "publish time", "发布范围", "范围", "范围与位置", "location"], { (0.2...0.85).contains($0.centerY) })
        if let filterDone, let reset, filterGroups.count >= 2 {
            return .init(scene: "xiaohongshu.filters", evidence: [filterDone.id, reset.id] + filterGroups.map(\.id))
        }
        if let filter, Set(tabs.map { baseLabel($0.label) }).count >= 2,
           brand != nil || search != nil || tabs.count >= 3 {
            return .init(scene: "xiaohongshu.results", evidence: [filter.id] + tabs.map(\.id) + [brand?.id, search?.id].compactMap { $0 })
        }
        if let search, let layout = nativeLatestLayout(in: snapshot) {
            return .init(scene: "xiaohongshu.results", evidence: [search.id, layout.all.id, layout.top.id, layout.latest.id] + tabs.map(\.id))
        }
        let profileID = elements.filter {
            let label = normalized($0.label)
            return $0.rect.centerY < 0.5 && (label.hasPrefix("小红书号") || label.hasPrefix("rednote id") || label.contains("xiaohongshu.com/user/profile/"))
        }
        let profileTabs = matches(["笔记", "notes", "收藏", "saved", "赞过", "liked"], { (0.25...0.72).contains($0.centerY) })
        if profileID.count == 1, profileTabs.count >= 2 {
            return .init(scene: "xiaohongshu.profile", evidence: [profileID[0].id] + profileTabs.map(\.id))
        }
        let follow = one(["关注", "follow", "已关注", "following"], { $0.centerY < 0.28 })
        let composer = one(["说点什么", "说点什么...", "说点什么…", "say something", "say something...", "add a comment", "write a comment", "write a comment..."], { $0.centerY > 0.65 })
        let toolbar = matches(["点赞", "赞", "like", "likes", "收藏", "save", "saved", "评论", "comments", "comment"], { $0.centerY > 0.72 })
        let source = elements.first { $0.label.contains("xiaohongshu.com/explore/") || $0.label.contains("xiaohongshu.com/discovery/item/") }
        if let follow, let composer, brand != nil || source != nil || toolbar.count >= 2 || noteOpenedFromResults {
            let evidence = [follow.id, composer.id] + [brand?.id, source?.id].compactMap { $0 } + toolbar.map(\.id)
            let comments = elements.first {
                let label = normalized($0.label)
                return (0.2...0.82).contains($0.rect.centerY) &&
                    (label.hasPrefix("共") && label.hasSuffix("条评论") || label.hasSuffix(" comments") || label.hasPrefix("comments "))
            }
            return .init(scene: comments == nil ? "xiaohongshu.note" : "xiaohongshu.comments", evidence: evidence + [comments?.id].compactMap { $0 })
        }
        return nil
    }

    static func explicitSelections(in snapshot: PhoneUISnapshot) -> [XiaohongshuSelectionEvidence] {
        snapshot.elements.compactMap { element in
            guard element.source == "ocr", element.rect.valid,
                  hasSelectedMarker(element.label) else { return nil }
            return .init(elementID: element.id, label: baseLabel(element.label), method: .explicitSelectedText,
                         capturedAt: snapshot.capturedAt, screenshotSHA256: nil)
        }
    }

    /// The caller samples the actual current CGImage. The fixed sampling grid
    /// only searches INSIDE/under observed text bounds, never guessed tap points.
    static func localSelectionEvidence(snapshot: PhoneUISnapshot, screenshotSHA256: String,
                                       sampleRGBA: (Double, Double) -> XiaohongshuPixel?) -> [XiaohongshuSelectionEvidence] {
        var result = explicitSelections(in: snapshot)
        for element in snapshot.elements where element.source == "ocr" && element.rect.valid && element.rect.centerY < 0.85 {
            var textRed = 0, underlineRed = 0, pinkChip = 0
            for x in 0..<15 {
                let px = element.rect.x + element.rect.width * (Double(x) + 0.5) / 15
                for y in 0..<7 {
                    let py = element.rect.y + element.rect.height * (Double(y) + 0.5) / 7
                    if sampleRGBA(px, py)?.isRed == true { textRed += 1 }
                }
                for offset in [0.005, 0.01, 0.015] {
                    let py = element.rect.y + element.rect.height + offset
                    if py <= 1, sampleRGBA(px, py)?.isRed == true { underlineRed += 1 }
                }
                for py in [element.rect.y - 0.004, element.rect.y + element.rect.height + 0.004] where py >= 0 && py <= 1 {
                    if sampleRGBA(px, py)?.isPinkTint == true { pinkChip += 1 }
                }
            }
            if textRed >= 5 && underlineRed >= 6 {
                result.append(.init(elementID: element.id, label: baseLabel(element.label), method: .redTextAndUnderline,
                    capturedAt: snapshot.capturedAt, screenshotSHA256: screenshotSHA256,
                    redTextSamples: textRed, redUnderlineSamples: underlineRed))
            } else if textRed >= 5 && pinkChip >= 12 {
                result.append(.init(elementID: element.id, label: baseLabel(element.label), method: .redTextAndFilledChip,
                    capturedAt: snapshot.capturedAt, screenshotSHA256: screenshotSHA256,
                    redTextSamples: textRed, pinkChipSamples: pinkChip))
            }
        }
        if let layout = nativeLatestLayout(in: snapshot), validSHA256(screenshotSHA256) {
            func samples(_ element: PhoneUIElement) -> (bright: Int, p95: Double) {
                var values: [Double] = [], bright = 0
                for x in 0..<15 { for y in 0..<7 {
                    if let p = sampleRGBA(element.rect.x + element.rect.width * (Double(x) + 0.5) / 15,
                                          element.rect.y + element.rect.height * (Double(y) + 0.5) / 7), p.alpha > 0.8 {
                        values.append((p.red + p.green + p.blue) / 3)
                        if min(p.red, p.green, p.blue) > 0.60 && max(p.red, p.green, p.blue) - min(p.red, p.green, p.blue) < 0.15 { bright += 1 }
                    }
                }}
                values.sort()
                return (bright, values.isEmpty ? 0 : values[Int(Double(values.count - 1) * 0.95)])
            }
            let allText = samples(layout.all), latestText = samples(layout.latest), topText = samples(layout.top)
            // Search a thin horizontal strip relative to the actual OCR bounds.
            // A sparse fixed offset can miss a one-pixel underline after raster scaling.
            var longestRedRow = 0
            for row in 2...22 {
                var red = 0, run = 0, longestRun = 0
                for x in 0..<30 {
                    let px = layout.all.rect.x - 0.008 + (layout.all.rect.width + 0.016) * (Double(x) + 0.5) / 30
                    let py = layout.all.rect.y + layout.all.rect.height + Double(row) * 0.001
                    if sampleRGBA(px, py)?.isRed == true { red += 1; run += 1; longestRun = max(longestRun, run) } else { run = 0 }
                }
                if longestRun >= 10 { longestRedRow = max(longestRedRow, red) }
            }
            if allText.bright >= 5 && longestRedRow >= 12 {
                result.append(.init(elementID: layout.all.id, label: baseLabel(layout.all.label), method: .neutralTextAndRedUnderline,
                    capturedAt: snapshot.capturedAt, screenshotSHA256: screenshotSHA256,
                    redUnderlineSamples: longestRedRow, neutralTextSamples: allText.bright, underlineFraction: Double(longestRedRow) / 30))
            }
            var chip = 0, surround: [Double] = [], background: [Double] = []
            for x in 0..<15 {
                let px = layout.latest.rect.x + layout.latest.rect.width * (Double(x) + 0.5) / 15
                for py in [layout.latest.rect.y - 0.003, layout.latest.rect.y - 0.007, layout.latest.rect.y + layout.latest.rect.height + 0.003, layout.latest.rect.y + layout.latest.rect.height + 0.007] {
                    if let p = sampleRGBA(px, py), p.alpha > 0.8 {
                        let luma = (p.red + p.green + p.blue) / 3
                        if (0.045...0.24).contains(luma), max(p.red,p.green,p.blue) - min(p.red,p.green,p.blue) < 0.06 { chip += 1; background.append(luma) }
                    }
                }
                for py in [layout.latest.rect.y - 0.020, layout.latest.rect.y + layout.latest.rect.height + 0.020] {
                    if let p = sampleRGBA(px, py), p.alpha > 0.8 { surround.append((p.red + p.green + p.blue) / 3) }
                }
            }
            background.sort(); surround.sort()
            let contrast = background.isEmpty || surround.isEmpty ? 0 : background[background.count / 2] - surround[surround.count / 2]
            if latestText.bright >= 5, topText.bright <= 2, latestText.p95 >= 0.60, topText.p95 <= 0.52,
               latestText.p95 - topText.p95 >= 0.18, chip >= 24, contrast >= 0.025 {
                result.append(.init(elementID: layout.latest.id, label: baseLabel(layout.latest.label), method: .nativeLatestContrastChip,
                    capturedAt: snapshot.capturedAt, screenshotSHA256: screenshotSHA256,
                    neutralTextSamples: latestText.bright, peerElementID: layout.top.id, textLuminance: latestText.p95,
                    peerTextLuminance: topText.p95, chipBackgroundSamples: chip, chipContrast: contrast))
            }
        }
        return result
    }
    static func selected(_ label: String, snapshot: PhoneUISnapshot, evidence: [XiaohongshuSelectionEvidence], screenshotSHA256: String?, requiredRole: String? = nil, allowExplicit: Bool = true) -> [String]? {
        let combined = evidence + (allowExplicit ? explicitSelections(in: snapshot) : [])
        let matches = combined.filter { value in
            guard let element = snapshot.element(id: value.elementID), value.capturedAt == snapshot.capturedAt,
                  value.label == baseLabel(element.label), sortKey(value.label) == sortKey(label),
                  element.rect.centerY >= 0.12,
                  element.rect.centerY < (identity(in: snapshot)?.scene == "xiaohongshu.filters" ? 0.88 : (nativeLatestLayout(in: snapshot)?.latest.id == element.id ? 0.85 : (["笔记", "notes"].contains(baseLabel(label)) ? 0.72 : 0.42))),
                  requiredRole == nil || selectionRole(element, snapshot: snapshot) == requiredRole else { return false }
            switch value.method {
            case .explicitSelectedText: return hasSelectedMarker(element.label)
            case .redTextAndUnderline:
                return validSHA256(screenshotSHA256) && value.screenshotSHA256 == screenshotSHA256 &&
                    value.redTextSamples >= 5 && value.redUnderlineSamples >= 6
            case .redTextAndFilledChip:
                return validSHA256(screenshotSHA256) && value.screenshotSHA256 == screenshotSHA256 &&
                    value.redTextSamples >= 5 && value.pinkChipSamples >= 12
            case .neutralTextAndRedUnderline:
                guard let fraction = value.underlineFraction, fraction.isFinite, (0.4...1).contains(fraction) else { return false }
                return nativeLatestLayout(in: snapshot)?.all.id == element.id && validSHA256(screenshotSHA256) &&
                    value.screenshotSHA256 == screenshotSHA256 && (5...105).contains(value.neutralTextSamples ?? 0) &&
                    (12...30).contains(value.redUnderlineSamples)
            case .nativeLatestContrastChip:
                guard let layout = nativeLatestLayout(in: snapshot), layout.latest.id == element.id,
                      value.peerElementID == layout.top.id,
                      let luma = value.textLuminance, let peer = value.peerTextLuminance,
                      luma.isFinite, peer.isFinite, luma >= 0.60, peer <= 0.52, peer >= 0, luma <= 1 else { return false }
                return validSHA256(screenshotSHA256) && value.screenshotSHA256 == screenshotSHA256 &&
                    (5...105).contains(value.neutralTextSamples ?? 0) && luma - peer >= 0.18 &&
                    (24...60).contains(value.chipBackgroundSamples ?? 0) && (value.chipContrast ?? 0) >= 0.025 && (value.chipContrast ?? 1) <= 1
            }
        }
        let ids = Set(matches.map(\.elementID))
        return ids.count == 1 ? Array(ids) : nil
    }
    static func validSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func nativeLatestScopeEvidence(snapshot: PhoneUISnapshot, evidence: [XiaohongshuSelectionEvidence], screenshotSHA256: String?) -> [String]? {
        guard let layout = nativeLatestLayout(in: snapshot),
              let category = selected("All", snapshot: snapshot, evidence: evidence.filter { $0.method == .neutralTextAndRedUnderline },
                  screenshotSHA256: screenshotSHA256, requiredRole: "category", allowExplicit: false),
              let sort = selected("Latest", snapshot: snapshot, evidence: evidence.filter { $0.method == .nativeLatestContrastChip },
                  screenshotSHA256: screenshotSHA256, requiredRole: "sort", allowExplicit: false),
              category == [layout.all.id], sort == [layout.latest.id] else { return nil }
        return category + sort
    }
    static func hasSelectedMarker(_ text: String) -> Bool {
        let value = normalized(text)
        return value.hasPrefix("已选：") || value.hasPrefix("已选:") || value.hasPrefix("selected:") ||
            ["（已选）", "(已选)", " 已选", " ✓", " ✔", " (selected)", " selected"].contains(where: value.hasSuffix)
    }
    static func selectionRole(_ element: PhoneUIElement, snapshot: PhoneUISnapshot) -> String {
        if let layout = nativeLatestLayout(in: snapshot), layout.latest.id == element.id { return "sort" }
        let raw = normalized(element.label)
        if ["排序：", "排序:", "sort:", "sort by:"].contains(where: raw.hasPrefix) { return "sort" }
        if identity(in: snapshot)?.scene == "xiaohongshu.filters" {
            let groups = snapshot.elements.filter { candidate in
                candidate.source == "ocr" && candidate.rect.centerY < element.rect.centerY &&
                    ["排序依据", "排序", "sort by", "sort", "笔记类型", "note type", "发布时间", "publish time", "发布范围", "范围", "范围与位置", "location"].contains(baseLabel(candidate.label))
            }.sorted { $0.rect.centerY > $1.rect.centerY }
            if let group = groups.first { return ["排序依据", "排序", "sort by", "sort"].contains(baseLabel(group.label)) ? "sort" : "filter" }
        }
        return "category"
    }
    static func filterControl(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let values = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY < 0.4 && ["筛选", "筛选中", "filter", "filters"].contains(normalized($0.label)) }
        return values.count == 1 ? values[0] : nil
    }
    static func closeFilterControl(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let values = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY > 0.25 && ["收起", "完成", "应用", "确认", "done", "apply", "confirm"].contains(normalized($0.label)) }
        return values.count == 1 ? values[0] : nil
    }
    static func shareControl(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let labels = ["分享", "share", "更多", "more", "...", "···", "•••", "⋯"]
        let values = snapshot.elements.filter {
            $0.rect.valid && $0.rect.centerX > 0.72 && $0.rect.centerY < 0.22 &&
                ($0.source == "ocr" && labels.contains(normalized($0.label)) || $0.source == "local_visual" && $0.label == "视觉:更多")
        }
        return values.count == 1 ? values[0] : nil
    }
    static func copyLinkControl(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let values = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY > 0.3 && ["复制链接", "复制笔记链接", "copy link", "copy note link"].contains(normalized($0.label)) }
        return values.count == 1 ? values[0] : nil
    }
    static func dismissShareControl(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let values = snapshot.elements.filter {
            $0.rect.valid && ($0.source == "ocr" && $0.rect.centerY > 0.42 && ["取消", "cancel", "关闭", "close"].contains(normalized($0.label)) ||
                $0.source == "local_visual" && $0.label == "视觉:关闭" && $0.rect.centerY > 0.25)
        }
        return values.count == 1 ? values[0] : nil
    }
    static func sameNoteText(_ lhs: PhoneUISnapshot, _ rhs: PhoneUISnapshot) -> Bool {
        let before = lhs.elements.filter { $0.source == "ocr" && (0.25...0.78).contains($0.rect.centerY) && $0.label.count >= 4 }.map(\.label)
        let after = Set(rhs.elements.filter { $0.source == "ocr" && (0.25...0.78).contains($0.rect.centerY) }.map(\.label))
        return !before.isEmpty && before.allSatisfy(after.contains)
    }
}
