import Foundation

public struct LaunchIssueReport: Equatable, Sendable {
  public let failure: LaunchFailure
  public let appVersion: String
  public let systemVersion: String

  public init(failure: LaunchFailure, appVersion: String, systemVersion: String) {
    self.failure = failure
    self.appVersion = appVersion
    self.systemVersion = systemVersion
  }

  public var url: URL {
    var components = URLComponents(string: Self.newIssueURL)!
    components.queryItems = [
      URLQueryItem(name: "title", value: failure.title),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url!
  }

  private var shortenedError: String {
    guard failure.message.count > Self.maximumErrorLength else { return failure.message }

    return "\(failure.message.prefix(Self.maximumErrorLength))… (shortened)"
  }

  private var body: String {
    """
    **What happened**
    \(failure.title)

    **Error**
    ```
    \(shortenedError)
    ```

    **Versions**
    - Codevisor \(appVersion)
    - macOS \(systemVersion)
    """
  }

  private static let newIssueURL = "https://github.com/851-labs/codevisor/issues/new"
  private static let maximumErrorLength = 1_500
}
