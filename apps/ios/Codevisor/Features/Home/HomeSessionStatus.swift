import Foundation

/// The visible status and updated-order tier shared by agent and workspace
/// rows. A running agent keeps its activity indicator even when it has
/// buffered unread turns, while a separate unread agent still outranks a
/// separate running agent when choosing a workspace's aggregate status.
enum HomeSessionStatus: Int, Comparable {
    case error = 0
    case actionRequired = 1
    case unread = 2
    case inProgress = 3
    case idle = 4

    static func < (left: Self, right: Self) -> Bool {
        left.rawValue < right.rawValue
    }
}
