import Foundation
public protocol ActivityAttributes {
    associatedtype ContentState: Codable & Hashable
}
public struct ActivityContent<State> {
    public var state: State
    public var staleDate: Date?
    public var relevanceScore: Double
    public init(state: State, staleDate: Date?, relevanceScore: Double = 0) { self.state = state; self.staleDate = staleDate; self.relevanceScore = relevanceScore }
}
public enum ActivityUIDismissalPolicy { case immediate, after(Date) }
@MainActor private var allActivities: [Any] = []
@MainActor public final class Activity<Attributes: ActivityAttributes> {
    public let attributes: Attributes
    public var content: ActivityContent<Attributes.ContentState>
    public var updates = 0
    public var endings = 0
    public var beforeUpdate: (() async -> Void)?
    public init(attributes: Attributes, content: ActivityContent<Attributes.ContentState>) { self.attributes = attributes; self.content = content }
    public static var activities: [Activity<Attributes>] { allActivities.compactMap { $0 as? Activity<Attributes> } }
    public static func request(attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: String?) throws -> Activity<Attributes> {
        let activity = Activity(attributes: attributes, content: content); allActivities.append(activity); return activity
    }
    public func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async {
        if let content { self.content = content }; endings += 1
    }
    public func update(_ content: ActivityContent<Attributes.ContentState>) async {
        await beforeUpdate?()
        self.content = content; updates += 1
    }
}
@MainActor public struct ActivityAuthorizationInfo {
    public static var enabled = true
    public init() {}
    public var areActivitiesEnabled: Bool { Self.enabled }
}
