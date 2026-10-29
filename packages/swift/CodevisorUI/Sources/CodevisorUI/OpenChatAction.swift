import CodevisorProtocol
import SwiftUI

extension EnvironmentValues {
  @Entry public var openChat: OpenChatAction?
}

public struct OpenChatAction: Sendable {
  private let handler: @MainActor @Sendable (ChatSession) async -> Void

  public init(_ handler: @escaping @MainActor @Sendable (ChatSession) async -> Void) {
    self.handler = handler
  }

  @MainActor public func callAsFunction(_ session: ChatSession) async { await handler(session) }
}
