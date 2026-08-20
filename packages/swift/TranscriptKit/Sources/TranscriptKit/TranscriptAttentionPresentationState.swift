/// Presentation-level inputs that must all hold before a rendered transcript
/// row can acknowledge unread attention. Row identity and viewport geometry
/// remain separate checks owned by the platform virtualizer.
public struct TranscriptAttentionPresentationState: Sendable, Equatable {
    public let isReadEligible: Bool
    public let isApplicationActive: Bool
    public let isWindowKey: Bool
    public let isWindowVisible: Bool
    public let isWindowOnScreen: Bool

    public init(
        isReadEligible: Bool,
        isApplicationActive: Bool,
        isWindowKey: Bool,
        isWindowVisible: Bool,
        isWindowOnScreen: Bool
    ) {
        self.isReadEligible = isReadEligible
        self.isApplicationActive = isApplicationActive
        self.isWindowKey = isWindowKey
        self.isWindowVisible = isWindowVisible
        self.isWindowOnScreen = isWindowOnScreen
    }

    public var allowsAcknowledgement: Bool {
        isReadEligible
            && isApplicationActive
            && isWindowKey
            && isWindowVisible
            && isWindowOnScreen
    }
}
