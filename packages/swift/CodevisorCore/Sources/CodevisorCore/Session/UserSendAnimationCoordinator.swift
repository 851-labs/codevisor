import Foundation

/// One request to animate a user message from the composer into its transcript
/// row. The token distinguishes requests even if a caller deliberately reuses
/// a message id.
public struct UserSendAnimationRequest: Equatable, Sendable {
    public let token: UInt64
    public let messageID: UUID

    public init(token: UInt64, messageID: UUID) {
        self.token = token
        self.messageID = messageID
    }
}

/// Exactly-once ownership for send animations. This state outlives native
/// transcript views, so rebuilding a SwiftUI/AppKit surface cannot claim the
/// same request again.
struct UserSendAnimationCoordinator {
    private var nextToken: UInt64 = 0
    private var currentRequest: UserSendAnimationRequest?
    private var claimedToken: UInt64?

    mutating func issue(for messageID: UUID) -> UserSendAnimationRequest {
        nextToken &+= 1
        let request = UserSendAnimationRequest(token: nextToken, messageID: messageID)
        currentRequest = request
        return request
    }

    mutating func claim(_ request: UserSendAnimationRequest) -> Bool {
        guard currentRequest == request, claimedToken != request.token else { return false }
        claimedToken = request.token
        return true
    }

    mutating func cancel(_ request: UserSendAnimationRequest) {
        guard currentRequest == request else { return }
        currentRequest = nil
    }
}
