public protocol ScreenSharingBackgroundSending<Message>: Sendable {
  associatedtype Message: Sendable
  @discardableResult func sendFromAnyThread(_ message: Message) -> Bool
}
