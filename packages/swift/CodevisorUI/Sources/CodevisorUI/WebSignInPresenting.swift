import Foundation

@MainActor
public protocol WebSignInPresenting: AnyObject {
  func run(_ url: URL, callbackScheme: String?) async
  func cancel()
}
