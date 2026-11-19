import Foundation

@MainActor
public enum DeviceDataTeardown {
  private static var steps: [@MainActor () async -> Void] = [
    { URLCache.shared.removeAllCachedResponses() },
    { HTTPCookieStorage.shared.removeCookies(since: .distantPast) },
  ]

  public static func register(_ step: @escaping @MainActor () async -> Void) {
    steps.append(step)
  }

  static func run() async {
    for step in steps {
      await step()
    }
  }
}
