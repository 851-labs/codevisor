import Foundation

public struct UserSendAnimationRequest: Equatable, Sendable {
  public let token: UInt64
  public let messageID: UUID

  public init(token: UInt64, messageID: UUID) {
    self.token = token
    self.messageID = messageID
  }
}

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
