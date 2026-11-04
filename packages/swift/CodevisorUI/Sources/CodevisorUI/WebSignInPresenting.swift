import Foundation

@MainActor
public protocol WebSignInPresenting: AnyObject {
  func run(_ url: URL) async
  func cancel()
}
