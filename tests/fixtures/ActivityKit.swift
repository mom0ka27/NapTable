import Foundation

// The host-side controller regression uses this small ActivityKit boundary.
// Like the actual API, update/end take effect when called: their timestamp
// orders events and does not defer execution until that time.
public protocol ActivityAttributes: Codable {
    associatedtype ContentState: Codable & Hashable
}

public struct ActivityContent<State> {
    public let state: State
    public let staleDate: Date?
    public init(state: State, staleDate: Date?) {
        self.state = state
        self.staleDate = staleDate
    }
}

public enum ActivityStyle { case standard, transient }

public struct LocalizedStringResource: ExpressibleByStringLiteral {
    public let value: String
    public init(stringLiteral value: String) { self.value = value }
}

public struct AlertConfiguration {
    public let title: LocalizedStringResource
    public let body: LocalizedStringResource
    public init(title: LocalizedStringResource, body: LocalizedStringResource, sound: AlertSound) {
        self.title = title
        self.body = body
    }
    public struct AlertSound {
        public static let `default` = AlertSound()
        public init() {}
    }
}

public enum ActivityState { case pending, active, stale, ended, dismissed }
public enum ActivityUIDismissalPolicy { case immediate }
public enum PushType: Equatable {
    case token
    case channel(String)
}

public enum ActivityAuthorizationError: Error { case targetMaximumExceeded, globalMaximumExceeded }

public enum TestActivityKit {
    public static var capacity = Int.max
    public static var capacityError = ActivityAuthorizationError.targetMaximumExceeded
    public static var requestAttempts = 0
    public static var activitiesEnabled = true
    public static var failNextRequest = false
    public static var events: [String] = []
    fileprivate static var activities: [AnyObject] = []
    fileprivate static var activityObservers: [(AnyObject) -> Void] = []
}

public struct ActivityAuthorizationInfo {
    public init() {}
    public var areActivitiesEnabled: Bool { TestActivityKit.activitiesEnabled }
}

public final class Activity<Attributes: ActivityAttributes> {
    public let id = UUID().uuidString
    public let attributes: Attributes
    public private(set) var content: ActivityContent<Attributes.ContentState>
    public private(set) var activityState: ActivityState = .active
    /// Test-only record of what `request` asked for; not part of ActivityKit.
    public let pushType: PushType?
    public private(set) var pushToken: Data?
    private var tokenContinuations: [AsyncStream<Data>.Continuation] = []

    public static var pushToStartTokenUpdates: AsyncStream<Data> { AsyncStream { $0.finish() } }

    /// Like ActivityKit, a new subscriber first receives the current token.
    public var pushTokenUpdates: AsyncStream<Data> {
        AsyncStream { continuation in
            if let pushToken { continuation.yield(pushToken) }
            if activityState == .ended || activityState == .dismissed { continuation.finish() } else { tokenContinuations.append(continuation) }
        }
    }

    public static var activityUpdates: AsyncStream<Activity<Attributes>> {
        AsyncStream { continuation in
            TestActivityKit.activityObservers.append { if let activity = $0 as? Activity<Attributes> { continuation.yield(activity) } }
        }
    }

    public static var activities: [Activity<Attributes>] {
        TestActivityKit.activities.compactMap { $0 as? Activity<Attributes> }
    }

    private init(attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: PushType?) {
        self.attributes = attributes
        self.content = content
        self.pushType = pushType
    }

    /// Test hook: the system issuing (or rotating) this activity's push token.
    public func deliverPushToken(_ token: Data) {
        pushToken = token
        for continuation in tokenContinuations { continuation.yield(token) }
    }

    /// Test hook: a scheduled reservation reaching its start time.
    public func begin() { activityState = .active }

    /// Test hook: the system creating an activity from a push-to-start (iOS 18).
    @discardableResult
    public static func remoteStart(attributes: Attributes, content: ActivityContent<Attributes.ContentState>) -> Activity<Attributes> {
        let activity = Activity(attributes: attributes, content: content, pushType: .token)
        TestActivityKit.activities.append(activity)
        for observer in TestActivityKit.activityObservers { observer(activity) }
        return activity
    }

    public static func request(
        attributes: Attributes,
        content: ActivityContent<Attributes.ContentState>,
        pushType: PushType?
    ) throws -> Activity<Attributes> {
        TestActivityKit.requestAttempts += 1
        if activities.filter({ $0.activityState != .ended && $0.activityState != .dismissed }).count >= TestActivityKit.capacity {
            throw TestActivityKit.capacityError
        }
        if TestActivityKit.failNextRequest {
            TestActivityKit.failNextRequest = false
            throw NSError(domain: "ActivityKit", code: 1)
        }
        let activity = Activity(attributes: attributes, content: content, pushType: pushType)
        TestActivityKit.activities.append(activity)
        TestActivityKit.events.append("request")
        for observer in TestActivityKit.activityObservers { observer(activity) }
        return activity
    }

    public static func request(
        attributes: Attributes,
        content: ActivityContent<Attributes.ContentState>,
        pushType: PushType?,
        style: ActivityStyle,
        alertConfiguration: AlertConfiguration,
        start: Date
    ) throws -> Activity<Attributes> {
        let activity = try request(attributes: attributes, content: content, pushType: pushType)
        activity.activityState = .pending
        return activity
    }

    public func update(_ content: ActivityContent<Attributes.ContentState>) async {
        self.content = content
        TestActivityKit.events.append("update")
    }

    public func update(_ content: ActivityContent<Attributes.ContentState>, timestamp: Date) async {
        await update(content)
    }

    public func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async {
        if let content { self.content = content }
        activityState = .ended
        TestActivityKit.events.append("end")
        for continuation in tokenContinuations { continuation.finish() }
        tokenContinuations = []
    }

    public func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy, timestamp: Date) async {
        await end(content, dismissalPolicy: dismissalPolicy)
    }
}
