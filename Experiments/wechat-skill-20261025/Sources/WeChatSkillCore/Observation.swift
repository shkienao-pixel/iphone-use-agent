import Foundation

public enum Surface: String, Codable, Sendable { case chat, momentDetail, momentActions, momentComposer, other }
public enum LikeState: String, Codable, Sendable { case likedBySelf, notLikedBySelf, unknown }
public enum ComposerKind: String, Codable, Sendable { case message, momentComment, reply }
public struct DraftEvidence: Codable, Equatable, Sendable {
    public var fieldID: String
    public var text: String
    public var kind: ComposerKind
    public var replyTarget: String?
    public init(fieldID: String, text: String, kind: ComposerKind, replyTarget: String? = nil) {
        self.fieldID = fieldID; self.text = text; self.kind = kind; self.replyTarget = replyTarget
    }
}
public enum ItemAuthor: String, Codable, Sendable { case myself, other, unknown }
public enum ItemState: String, Codable, Sendable { case normal, pending, failed }
public enum LandmarkKind: String, Codable, Sendable { case timestamp, conversationStart }
public struct VisibleLandmark: Codable, Equatable, Sendable {
    public var kind: LandmarkKind
    public var text: String
    public var frameID: UUID
    public var source: ControlSource
    public var precedingItemID: String?
    public var followingItemID: String?
    public init(kind: LandmarkKind, text: String, frameID: UUID, source: ControlSource,
                precedingItemID: String? = nil, followingItemID: String? = nil) {
        self.kind = kind; self.text = text; self.frameID = frameID; self.source = source
        self.precedingItemID = precedingItemID; self.followingItemID = followingItemID
    }
}
public struct VisibleItem: Codable, Equatable, Sendable {
    /// Local correspondence ID established from observed content/neighborhood.
    /// Not a hidden WeChat message ID; ambiguity must be reported by the adapter.
    public var id: String
    public var text: String
    public var author: ItemAuthor
    public var state: ItemState
    public init(id: String, text: String, author: ItemAuthor, state: ItemState = .normal) {
        self.id = id; self.text = text; self.author = author; self.state = state
    }
}

/// Trusted adapter input. No function in this package generates it from model
/// prose, screenshots, AX or OCR. Raw screenshot recognition remains unimplemented.
public struct SceneObservation: Codable, Equatable, Sendable {
    public var frame: FrameStamp
    public var account: String
    public var contactProofID: UUID
    public var momentBindingID: UUID?
    public var surface: Surface
    public var controls: [ObservedControl]
    public var draft: DraftEvidence?
    public var items: [VisibleItem]
    public var continuityAnchors: [String]
    public var listVerifiedEmpty: Bool
    public var correspondenceUnambiguous: Bool
    public var like: LikeState
    public var blockingOverlay: Bool
    /// Literal, sourced UI landmarks, not cross-process local anchor IDs.
    public var landmarks: [VisibleLandmark]?
    public init(frame: FrameStamp, account: String, contactProofID: UUID, momentBindingID: UUID? = nil,
                surface: Surface, controls: [ObservedControl] = [], draft: DraftEvidence? = nil,
                items: [VisibleItem] = [], continuityAnchors: [String] = [], listVerifiedEmpty: Bool = false,
                correspondenceUnambiguous: Bool = false, like: LikeState = .unknown, blockingOverlay: Bool = false,
                landmarks: [VisibleLandmark]? = nil) {
        self.frame = frame; self.account = account; self.contactProofID = contactProofID
        self.momentBindingID = momentBindingID; self.surface = surface; self.controls = controls
        self.draft = draft; self.items = items; self.continuityAnchors = continuityAnchors
        self.listVerifiedEmpty = listVerifiedEmpty; self.correspondenceUnambiguous = correspondenceUnambiguous
        self.like = like; self.blockingOverlay = blockingOverlay
        self.landmarks = landmarks
    }
    func validate(mode: EvaluationMode, now: Date, maxAge: TimeInterval) throws {
        try frame.validate(mode: mode, now: now, maxAge: maxAge)
        guard nonblank(account), !blockingOverlay,
              Set(controls.map(\.id)).count == controls.count,
              controls.allSatisfy({ $0.frameID == frame.id && $0.rect.valid && nonblank($0.id) &&
                  $0.source != .modelGuess && (mode == .offline ? $0.source == .fixture : $0.source != .fixture) }),
              Set(items.map(\.id)).count == items.count, items.allSatisfy({ nonblank($0.id) }),
              Set(continuityAnchors).count == continuityAnchors.count,
              continuityAnchors.allSatisfy(nonblank), !(listVerifiedEmpty && !items.isEmpty)
        else { throw SkillError.invalidObservation }
        for landmark in landmarks ?? [] {
            guard landmark.frameID == frame.id, nonblank(landmark.text), landmark.source != .modelGuess,
                  (mode == .offline ? landmark.source == .fixture : landmark.source != .fixture)
            else { throw SkillError.invalidObservation }
            let preceding = landmark.precedingItemID.flatMap { id in items.firstIndex { $0.id == id } }
            let following = landmark.followingItemID.flatMap { id in items.firstIndex { $0.id == id } }
            guard landmark.precedingItemID == nil || preceding != nil,
                  landmark.followingItemID == nil || following != nil else { throw SkillError.invalidObservation }
            if let preceding, let following, following != preceding + 1 { throw SkillError.invalidObservation }
            if landmark.kind == .conversationStart {
                guard preceding == nil, items.isEmpty ? listVerifiedEmpty : following == 0 else { throw SkillError.invalidObservation }
            } else if preceding == nil && following == nil { throw SkillError.invalidObservation }
        }
    }
}
