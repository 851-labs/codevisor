import CodevisorProtocol
import SwiftUI

extension EnvironmentValues {
  @Entry public var openChat: OpenChatAction?
}

public struct OpenChatAction: Sendable, Equatable {
  private let identity: HandlerIdentity
  private let handler: @MainActor @Sendable (ChatSession) async -> Void

  public init(identity: HandlerIdentity, _ handler: @escaping @MainActor @Sendable (ChatSession) async -> Void) {
    self.identity = identity
    self.handler = handler
  }

  @MainActor public func callAsFunction(_ session: ChatSession) async { await handler(session) }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}
