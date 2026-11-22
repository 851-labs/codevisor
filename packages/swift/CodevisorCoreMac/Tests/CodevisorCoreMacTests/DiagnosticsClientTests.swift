import CodevisorCore
import Sentry
import Testing
@testable import CodevisorCoreMac

@MainActor
@Suite("Diagnostics privacy primitives")
struct DiagnosticsClientTests {
  @Test("Handled issue names are a closed, content-free allowlist")
  func issueAllowlist() {
    #expect(
      Set(DiagnosticIssueName.allCases.map(\.rawValue)) == [
        "corrupt_persisted_data",
        "data_directory_unavailable",
        "persistence_write_failed",
        "terminal_open_failed",
        "app_relaunch_failed",
      ])
  }

  @Test("Sanitizer strips user content and keeps only scrubbed, allowlisted technical data")
  func sanitizer() {
    let (event, frame, exception) = privateEvent()

    let sanitized = DiagnosticsPrivacyFilter.sanitize(event)

    #expect(sanitized.user == nil)
    #expect(sanitized.request == nil)
    #expect(sanitized.message?.formatted == "Couldn't open <path>")
    #expect(sanitized.extra == nil)
    #expect(sanitized.modules == nil)
    #expect(
      sanitized.tags == [
        "component": "persistence",
        "diagnostic_issue": "persistence_write_failed",
        "machine_kind": "remote",
        "sync_event_kind": "session.attention.updated",
        "flag_developerMode": "true",
        "update_channel": "alpha",
      ])
    #expect(
      sanitized.context?["app"]?.keys.sorted() == [
        "app_build", "app_identifier", "app_version",
      ])
    #expect(sanitized.context?["os"]?.keys.sorted() == ["name", "version"])
    #expect(sanitized.context?["device"]?.keys.sorted() == ["arch"])
    #expect(sanitized.context?["private"] == nil)
    #expect(sanitized.context?["reported_error"]?["detail"] as? String == "write failed at <path>")
    #expect(sanitized.context?["reported_error"]?.keys.sorted() == ["detail", "error_type"])
    #expect(frame.fileName == "Session.swift")
    #expect(frame.package == "Codevisor")
    #expect(frame.contextLine == nil)
    #expect(frame.preContext == nil)
    #expect(frame.postContext == nil)
    #expect(frame.vars == nil)
    #expect(exception.value == "private prompt at <path>")
  }

  private func privateEvent() -> (Event, Frame, Exception) {
    let event = Event(level: .error)
    event.user = User(userId: "private-account-id")
    let request = SentryRequest()
    request.url = "https://example.com/private/repository"
    request.headers = ["Authorization": "secret"]
    event.request = request
    event.message = SentryMessage(formatted: "Couldn't open /Users/person/private/repo")
    event.extra = ["prompt": "private prompt"]
    event.modules = ["private-module": "1"]
    event.tags = [
      "component": "persistence",
      "diagnostic_issue": "persistence_write_failed",
      "machine_kind": "remote",
      "sync_event_kind": "session.attention.updated",
      "private_project": "secret",
      "flag_developerMode": "true",
      "update_channel": "alpha",
    ]
    event.context = privateContext()
    let frame = privateFrame()
    event.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
    let exception = Exception(value: "private prompt at /Users/person/private", type: "InternalError")
    exception.stacktrace = event.stacktrace
    event.exceptions = [exception]
    return (event, frame, exception)
  }

  private func privateContext() -> [String: [String: Any]] {
    [
      "app": [
        "app_identifier": "com.851labs.Codevisor",
        "app_version": "1.2.3",
        "app_build": "42",
        "app_name": "private",
      ],
      "os": ["name": "macOS", "version": "26.0", "raw_description": "private"],
      "device": ["arch": "arm64", "name": "Private Mac"],
      "private": ["path": "/Users/person/secret"],
      "reported_error": [
        "detail": "write failed at /Users/person/secret", "error_type": "POSIX 28", "prompt": "x",
      ],
    ]
  }

  private func privateFrame() -> Frame {
    let frame = Frame()
    frame.fileName = "/Users/person/private/Session.swift"
    frame.package = "/Applications/Codevisor.app/Contents/MacOS/Codevisor"
    frame.contextLine = "let prompt = privateContent"
    frame.preContext = ["private source"]
    frame.postContext = ["private source"]
    frame.vars = ["prompt": "private"]
    return frame
  }
}
