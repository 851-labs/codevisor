import Foundation
import Testing
@testable import CodevisorCore

@Suite("Review pane viewed marks")
struct ReviewPanePreferencesTests {
  @Test("A viewed mark holds only for the change it was made on")
  func viewedMarkLapsesOnNewerChange() {
    var preferences = ReviewPanePreferences()
    preferences.setViewed(true, path: "a.swift", fingerprint: "1..2", current: ["a.swift"])

    #expect(preferences.isViewed(path: "a.swift", fingerprint: "1..2"))
    // The file changed again after it was viewed.
    #expect(!preferences.isViewed(path: "a.swift", fingerprint: "1..3"))
    // Servers without fingerprints can't be tracked.
    #expect(!preferences.isViewed(path: "a.swift", fingerprint: nil))

    preferences.setViewed(false, path: "a.swift", fingerprint: "1..2", current: ["a.swift"])
    #expect(!preferences.isViewed(path: "a.swift", fingerprint: "1..2"))
  }

  @Test("Marks for files no longer under review are dropped when marking")
  func marksArePruned() {
    var preferences = ReviewPanePreferences(viewed: ["gone.swift": "1..2", "kept.swift": "3..4"])
    preferences.setViewed(
      true, path: "new.swift", fingerprint: "5..6", current: ["kept.swift", "new.swift"])

    #expect(preferences.viewed == ["kept.swift": "3..4", "new.swift": "5..6"])
  }

  @Test("Viewed marks sync through the pane record, and older records carry none")
  func viewedMarksRoundTripThroughPaneRecord() throws {
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .review, name: "Review", terminalKey: id.uuidString,
      review: ReviewPanePreferences(mode: .staged, viewed: ["a.swift": "1..2"]))
    let record = WorkspaceSyncModel.serverPane(from: pane, workspaceId: UUID(), createdAt: Date())
    #expect(WorkspaceSyncModel.descriptor(from: record)?.review == pane.review)

    let legacy = try JSONDecoder().decode(ReviewPanePreferences.self, from: Data(#"{"mode":"staged"}"#.utf8))
    #expect(legacy.viewed.isEmpty)
  }
}
