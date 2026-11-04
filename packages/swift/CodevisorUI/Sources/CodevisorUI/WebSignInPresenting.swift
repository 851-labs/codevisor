import Foundation

@MainActor
public protocol WebSignInPresenting: AnyObject {
  @discardableResult func run(_ url: URL) async -> URL?
  func cancel()
}
