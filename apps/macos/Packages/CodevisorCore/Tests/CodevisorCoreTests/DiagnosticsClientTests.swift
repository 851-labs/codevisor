import Sentry
import Testing
@testable import CodevisorCore

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
                "project_sync_failed",
                "bulk_sync_failed",
                "server_delete_failed",
                "terminal_open_failed",
                "app_relaunch_failed",
            ])
    }

    @Test("Sanitizer strips user content and keeps only allowlisted technical data")
    func sanitizer() {
        let event = Event(level: .error)
        event.user = User(userId: "private-account-id")

        let request = SentryRequest()
        request.url = "https://example.com/private/repository"
        request.headers = ["Authorization": "secret"]
        event.request = request

        event.message = SentryMessage(formatted: "private prompt or server response")
        event.extra = ["prompt": "private prompt"]
        event.modules = ["private-module": "1"]
        event.tags = [
            "component": "sync",
            "diagnostic_issue": "bulk_sync_failed",
            "private_project": "secret",
        ]
        event.context = [
            "app": [
                "app_identifier": "com.851labs.Codevisor",
                "app_version": "1.2.3",
                "app_build": "42",
                "app_name": "private",
            ],
            "os": ["name": "macOS", "version": "26.0", "raw_description": "private"],
            "device": ["arch": "arm64", "name": "Private Mac"],
            "private": ["path": "/Users/person/secret"],
        ]

        let frame = Frame()
        frame.fileName = "/Users/person/private/Session.swift"
        frame.package = "/Applications/Codevisor.app/Contents/MacOS/Codevisor"
        frame.contextLine = "let prompt = privateContent"
        frame.preContext = ["private source"]
        frame.postContext = ["private source"]
        frame.vars = ["prompt": "private"]
        event.stacktrace = SentryStacktrace(frames: [frame], registers: [:])

        let exception = Exception(
            value: "private prompt at /Users/person/private",
            type: "InternalError"
        )
        exception.stacktrace = event.stacktrace
        event.exceptions = [exception]

        let sanitized = DiagnosticsPrivacyFilter.sanitize(event)

        #expect(sanitized.user == nil)
        #expect(sanitized.request == nil)
        #expect(sanitized.message == nil)
        #expect(sanitized.extra == nil)
        #expect(sanitized.modules == nil)
        #expect(
            sanitized.tags == [
                "component": "sync",
                "diagnostic_issue": "bulk_sync_failed",
            ])
        #expect(
            sanitized.context?["app"]?.keys.sorted() == [
                "app_build", "app_identifier", "app_version",
            ])
        #expect(sanitized.context?["os"]?.keys.sorted() == ["name", "version"])
        #expect(sanitized.context?["device"]?.keys.sorted() == ["arch"])
        #expect(sanitized.context?["private"] == nil)
        #expect(frame.fileName == "Session.swift")
        #expect(frame.package == "Codevisor")
        #expect(frame.contextLine == nil)
        #expect(frame.preContext == nil)
        #expect(frame.postContext == nil)
        #expect(frame.vars == nil)
        #expect(exception.value == nil)
    }
}
