import CodevisorProtocol
import Foundation

extension Project {
    /// The fixed identity of the composer's "no project picked yet" sentinel.
    public static let runTargetPlaceholderID = UUID(
        uuidString: "00000000-0000-0000-0000-00000000C0DE"
    )!

    /// A sentinel project for a draft that exists BEFORE any project does:
    /// the new-chat composer always renders, with send disabled and the
    /// run-target chip prompting for a selection, instead of a bespoke
    /// empty screen.
    public static func runTargetPlaceholder(serverId: String) -> Project {
        fromFolder(
            URL(fileURLWithPath: "/"),
            id: runTargetPlaceholderID,
            serverId: serverId
        )
    }

    public var isRunTargetPlaceholder: Bool {
        id == Self.runTargetPlaceholderID
    }
}
