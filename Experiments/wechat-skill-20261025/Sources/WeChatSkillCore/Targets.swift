import Foundation

public enum SearchSection: String, Codable, Sendable { case contacts, groups, chatHistory, internet, searchID }
public struct ContactCandidate: Codable, Equatable, Sendable {
    public var rowID: String
    public var section: SearchSection
    public var name: String
    public var account: String?
    public init(rowID: String, section: SearchSection, name: String, account: String? = nil) {
        self.rowID = rowID; self.section = section; self.name = name; self.account = account
    }
}
public enum ContactSelection: Equatable, Sendable {
    case candidate(String), ambiguous([String]), noneInObservedResults
}

public struct MomentCandidate: Codable, Equatable, Sendable {
    public var localID: String
    public var ownerAccount: String?
    public var dateLabel: String?
    public var explicitYear: Int?
    public var body: String
    public var bodyComplete: Bool
    public var mediaDescription: String?
    public var isDetail: Bool
    public init(localID: String, ownerAccount: String?, dateLabel: String? = nil, explicitYear: Int? = nil,
                body: String, bodyComplete: Bool, mediaDescription: String? = nil, isDetail: Bool) {
        self.localID = localID; self.ownerAccount = ownerAccount; self.dateLabel = dateLabel
        self.explicitYear = explicitYear; self.body = body; self.bodyComplete = bodyComplete
        self.mediaDescription = mediaDescription; self.isDetail = isDetail
    }
}
public enum MatchQuality: Equatable, Sendable { case match, needsDetail, different }
public enum MomentSelection: Equatable, Sendable {
    case unique(String), inspectDetails([String]), ambiguous([String]), noneInObservedRange
}

public enum TargetMatcher {
    public static func contact(_ query: ContactQuery, candidates: [ContactCandidate]) throws -> ContactSelection {
        try query.validate()
        guard Set(candidates.map(\.rowID)).count == candidates.count,
              candidates.allSatisfy({ nonblank($0.rowID) && nonblank($0.name) }) else { throw SkillError.invalidObservation }
        let possible = candidates.filter { item in
            item.section == .contacts &&
            (query.expectedName.map { exact($0, item.name) } ?? true) &&
            (query.expectedAccount.map { wanted in item.account.map { exact(wanted, $0) } ?? true } ?? true)
        }.map(\.rowID)
        if possible.count == 1 { return .candidate(possible[0]) }
        return possible.isEmpty ? .noneInObservedResults : .ambiguous(possible)
    }

    public static func quality(_ candidate: MomentCandidate, account: String, clues: MomentClues) -> MatchQuality {
        var missing = !candidate.isDetail
        if let owner = candidate.ownerAccount { if !exact(owner, account) { return .different } }
        else { missing = true }
        if let wanted = clues.dateLabel {
            if let actual = candidate.dateLabel { if !exact(wanted, actual) { return .different } }
            else { missing = true }
        }
        if let wanted = clues.explicitYear {
            if let actual = candidate.explicitYear { if actual != wanted { return .different } }
            else { missing = true }
        }
        if let excerpt = clues.bodyExcerpt {
            // Literal UTF-8 subsequence: do not normalize or rewrite a quote.
            if candidate.body.range(of: excerpt, options: .literal) == nil {
                if candidate.bodyComplete { return .different }
                missing = true
            }
        }
        if let wanted = clues.mediaDescription {
            if let actual = candidate.mediaDescription { if !exact(wanted, actual) { return .different } }
            else { missing = true }
        }
        return missing ? .needsDetail : .match
    }

    public static func moment(account: String, clues: MomentClues, candidates: [MomentCandidate]) throws -> MomentSelection {
        try clues.validate()
        guard nonblank(account), Set(candidates.map(\.localID)).count == candidates.count,
              candidates.allSatisfy({ nonblank($0.localID) }) else { throw SkillError.invalidObservation }
        let matches = candidates.filter { quality($0, account: account, clues: clues) == .match }.map(\.localID)
        let unresolved = candidates.filter { quality($0, account: account, clues: clues) == .needsDetail }.map(\.localID)
        // One apparent match cannot win over another plausible, truncated post.
        if !unresolved.isEmpty { return .inspectDetails(matches + unresolved) }
        if matches.count == 1 { return .unique(matches[0]) }
        return matches.isEmpty ? .noneInObservedRange : .ambiguous(matches)
    }
}
