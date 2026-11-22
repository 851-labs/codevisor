import ACPKit
import CodevisorClient
import CodevisorTestSupport
import Foundation
import Synchronization
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First-run folder questions")
struct FirstRunFolderAccessTests {
  private static let documents = ServerFirstRunFolder(
    id: "documents", name: "Documents", path: "/Users/me/Documents", projects: ["api"])
  private static let desktop = ServerFirstRunFolder(
    id: "desktop", name: "Desktop", path: "/Users/me/Desktop", projects: ["site"])
  private static let downloads = ServerFirstRunFolder(
    id: "downloads", name: "Downloads", path: "/Users/me/Downloads", projects: ["demo"])

  @Test("Reports a drive's folder answer by kind, never by the drive's name")
  func reportsDrivesWithoutTheirNames() async {
    let driveName = "Private-Drive-\(UUID().uuidString)"
    let drive = ServerFirstRunFolder(
      id: "volume:\(driveName)", name: driveName, path: "/Volumes/\(driveName)", projects: ["vault"])
    let events = RecordingAnalyticsSink()
    Analytics.sink = events
    defer { Analytics.sink = nil }
    let client = FirstRunQuestionsClient(asking: [drive])
    let access = FirstRunFolderAccess(client: client) { _ in .allowed }
    let following = Task { await access.follow() }

    await client.answered.wait(for: 1)
    client.publish(asking: [])
    await following.value

    #expect(
      events.captured.contains {
        $0.properties["folder"] == .string("volume") && $0.properties["choice"] == .string("already_allowed")
      })
    #expect(!events.captured.contains { $0.properties.values.contains { "\($0)".contains(driveName) } })
  }

  @Test("Asks only about folders macOS hasn't decided, and answers the rest by itself")
  func asksAboutUndecidedFolders() async {
    let client = FirstRunQuestionsClient(asking: [Self.documents, Self.desktop, Self.downloads])
    let access = FirstRunFolderAccess(client: client) { folder in
      ["desktop": .allowed, "downloads": .denied][folder.id] ?? .undetermined
    }
    let following = Task { await access.follow() }

    await client.answered.wait(for: 2)
    #expect(access.asking == [Self.documents])
    #expect(client.answers == [.init(id: "desktop", access: .allow), .init(id: "downloads", access: .decline)])

    client.publish(asking: [])
    await following.value
    #expect(!access.isAsking)
  }

  @Test("Keeps a folder up while the server works on its answer, then moves to the next")
  func movesToTheNextFolder() async {
    let client = FirstRunQuestionsClient(asking: [Self.documents, Self.desktop])
    let access = FirstRunFolderAccess(client: client) { _ in .undetermined }
    let following = Task { await access.follow() }
    await awaitObserved { access.asking.count == 2 }

    await access.answer(Self.documents, allow: true)
    #expect(access.current == Self.documents)
    #expect(access.answeringId == "documents")
    #expect(client.answers == [.init(id: "documents", access: .allow)])

    client.publish(asking: [Self.desktop])
    await awaitObserved { access.current == Self.desktop }
    #expect(access.answeringId == nil)
    #expect(access.answered == 1)

    client.publish(asking: [])
    await following.value
  }

  @Test("Drops a folder whose answer can't be sent, so the sheet never traps the user")
  func dropsAFolderItCannotAnswer() async {
    let client = FirstRunQuestionsClient(asking: [Self.documents], refusesAnswers: true)
    let access = FirstRunFolderAccess(client: client) { _ in .undetermined }
    let following = Task { await access.follow() }
    await awaitObserved { access.isAsking }

    await access.answer(Self.documents, allow: true)
    #expect(!access.isAsking)
    #expect(access.answeringId == nil)

    client.publish(asking: [])
    await following.value
  }
}

@MainActor
private final class RecordingAnalyticsSink: AnalyticsSink {
  struct Event {
    let name: AnalyticsEventName
    let properties: [String: AnalyticsPropertyValue]
  }

  private(set) var captured: [Event] = []

  func setEnabled(_ enabled: Bool) {}

  func setContext(_ context: TelemetryContext) {}

  func capture(_ event: AnalyticsEventName, properties: [String: AnalyticsPropertyValue]) {
    captured.append(Event(name: event, properties: properties))
  }
}
