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
    public init(frame: FrameStamp, account: String, contactProofID: UUID, momentBindingID: UUID? = nil,
                surface: Surface, controls: [ObservedControl] = [], draft: DraftEvidence? = nil,
                items: [VisibleItem] = [], continuityAnchors: [String] = [], listVerifiedEmpty: Bool = false,
                correspondenceUnambiguous: Bool = false, like: LikeState = .unknown, blockingOverlay: Bool = false) {
        self.frame = frame; self.account = account; self.contactProofID = contactProofID
        self.momentBindingID = momentBindingID; self.surface = surface; self.controls = controls
        self.draft = draft; self.items = items; self.continuityAnchors = continuityAnchors
        self.listVerifiedEmpty = listVerifiedEmpty; self.correspondenceUnambiguous = correspondenceUnambiguous
        self.like = like; self.blockingOverlay = blockingOverlay
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
    }
}
