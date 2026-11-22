import CodevisorCore
import Foundation
import Sentry

enum DiagnosticsPrivacyFilter {
  static let reportedContextKey = "reported_error"

  private static let allowedTags = Set([
    "component", "diagnostic_issue", "machine_kind", "sync_event_kind", "update_channel", "feature_flags",
  ])
  private static let reportedContextFields = ["detail", "error_type"]

  static func reportedContext(_ error: ReportedError) -> [String: Any] {
    var context: [String: Any] = [:]
    context["detail"] = error.detail
    context["error_type"] = error.errorType
    return context
  }

  static func sanitize(_ event: Event) -> Event {
    event.user = nil
    event.request = nil
    event.serverName = nil
    event.logger = nil
    event.transaction = nil
    event.extra = nil
    event.modules = nil
    event.breadcrumbs = nil
    event.error = nil

    event.tags = event.tags?.filter { isAllowedTag($0.key) }
    sanitizeMessage(of: event)
    event.context = sanitizedContext(event.context)

    for exception in event.exceptions ?? [] {
      exception.value = exception.value.map(DiagnosticsScrubber.scrub)
      sanitize(exception.stacktrace)
    }
    for thread in event.threads ?? [] {
      thread.name = nil
      sanitize(thread.stacktrace)
    }
    sanitize(event.stacktrace)
    for image in event.debugMeta ?? [] {
      image.codeFile = lastPathComponent(image.codeFile)
    }
    return event
  }

  private static func isAllowedTag(_ key: String) -> Bool {
    allowedTags.contains(key) || key.hasPrefix(TelemetryContext.flagPrefix)
  }

  private static func sanitizeMessage(of event: Event) {
    guard let message = event.message else { return }
    guard event.tags?["diagnostic_issue"] != nil else {
      event.message = nil
      return
    }
    event.message = SentryMessage(formatted: DiagnosticsScrubber.scrub(message.formatted))
  }

  private static func sanitizedContext(
    _ context: [String: [String: Any]]?
  ) -> [String: [String: Any]]? {
    guard let context else { return nil }
    var result: [String: [String: Any]] = [:]
    copy(["app_identifier", "app_version", "app_build"], from: context["app"], to: &result, key: "app")
    copy(["name", "version"], from: context["os"], to: &result, key: "os")
    copy(["arch"], from: context["device"], to: &result, key: "device")
    copyScrubbed(reportedContextFields, from: context[reportedContextKey], to: &result, key: reportedContextKey)
    return result.isEmpty ? nil : result
  }

  private static func copy(
    _ keys: [String],
    from source: [String: Any]?,
    to destination: inout [String: [String: Any]],
    key: String
  ) {
    guard let source else { return }
    let values = source.filter { keys.contains($0.key) }
    if !values.isEmpty {
      destination[key] = values
    }
  }

  private static func copyScrubbed(
    _ keys: [String],
    from source: [String: Any]?,
    to destination: inout [String: [String: Any]],
    key: String
  ) {
    let strings = (source ?? [:]).compactMapValues { $0 as? String }
    copy(keys, from: strings.mapValues(DiagnosticsScrubber.scrub), to: &destination, key: key)
  }

  private static func sanitize(_ stacktrace: SentryStacktrace?) {
    for frame in stacktrace?.frames ?? [] {
      frame.fileName = lastPathComponent(frame.fileName)
      frame.package = lastPathComponent(frame.package)
      frame.contextLine = nil
      frame.preContext = nil
      frame.postContext = nil
      frame.vars = nil
    }
  }

  private static func lastPathComponent(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return value }
    return (value as NSString).lastPathComponent
  }
}
