import Foundation

public struct ReportedError: Sendable, Equatable {
  public static let unnamedIssue = "reported_error"

  public let title: String
  public let detail: String?
  public let issue: String
  public let component: String
  public let errorType: String?

  public init(
    title: String,
    detail: String?,
    issue: DiagnosticIssueName? = nil,
    component: String = "app",
    error: (any Error)? = nil
  ) {
    self.title = DiagnosticsScrubber.scrub(title)
    self.detail = detail.map(DiagnosticsScrubber.scrub)
    self.issue = issue?.rawValue ?? Self.unnamedIssue
    self.component = issue?.component ?? component
    errorType = error.map(Self.describeType)
  }

  private static func describeType(_ error: any Error) -> String {
    guard type(of: error) is NSError.Type else { return String(reflecting: type(of: error)) }
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
  }
}
