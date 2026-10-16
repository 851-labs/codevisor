import AppKit
import ApplicationServices
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use interaction regressions")
struct ComputerUseInteractionTests {
  @Test("Cold launch waits through missing windows and a transient AX timeout")
  func windowReadiness() throws {
    var reads = 0
    var time: TimeInterval = 0
    var delays: [TimeInterval] = []
    let window = try computerUseReadReadyWindow(
      timeout: 1, now: { time },
      sleep: {
        delays.append($0)
        time += $0
      }
    ) {
      reads += 1
      if reads == 1 { throw ComputerUseNoWindow() }
      if reads == 2 { throw ComputerUseWindowReadError(code: .cannotComplete) }
      return "ready"
    }
    #expect(window == "ready")
    #expect(reads == 3)
    #expect(delays == [0.1, 0.1])
  }

  @Test("Window readiness preserves permission errors and stops at its deadline")
  func windowReadinessFailures() {
    var reads = 0
    #expect(throws: ComputerUseWindowReadError.self) {
      try computerUseReadReadyWindow(
        timeout: 1, now: { 0 },
        sleep: { _ in
          Issue.record("Permission errors must not schedule another read")
        }
      ) { () -> String in
        reads += 1
        throw ComputerUseWindowReadError(code: .apiDisabled)
      }
    }
    #expect(reads == 1)
    #expect(throws: ComputerUseWindowReadError.self) {
      try computerUseReadReadyWindow(
        timeout: 0, now: { 0 },
        sleep: { _ in
          Issue.record("An expired deadline must not schedule another read")
        }
      ) { () -> String in
        reads += 1
        throw ComputerUseWindowReadError(code: .cannotComplete)
      }
    }
    #expect(reads == 2)
  }

  @Test("Window readiness retries until the controlled deadline and preserves the final AX error")
  func windowReadinessDeadline() {
    var time: TimeInterval = 0
    var observations: [TimeInterval] = []
    #expect(throws: ComputerUseWindowReadError.self) {
      try computerUseReadReadyWindow(timeout: 1, retryDelay: 0.25, now: { time }, sleep: { time += $0 }) {
        () -> String in
        observations.append(time)
        throw ComputerUseWindowReadError(code: .cannotComplete)
      }
    }
    #expect(observations == [0, 0.25, 0.5, 0.75, 1])
  }

  @Test("Values include control states and redact secure text fields")
  func observationValues() {
    #expect(computerUseObservationValue(role: "AXCheckBox", subrole: nil, value: NSNumber(value: true)) == "1")
    #expect(
      computerUseObservationValue(role: "AXTextField", subrole: "AXSecureTextField", value: "secret") == "<redacted>")
    #expect(computerUseObservationValue(role: "AXTextField", subrole: nil, value: "query") == "query")
    #expect(computerUseObservationValue(role: "AXButton", subrole: nil, value: nil).isEmpty)
  }

  @Test("Attribute writes distinguish confirmed, uncertain and rejected results")
  func mutationOutcomes() throws {
    let bridge = ComputerUseBridge()
    #expect(
      try bridge.accessibilityMutationResult(error: .cannotComplete, kind: "set_value", verified: true)["status"]
        as? String == "delivered")
    let uncertain = try bridge.accessibilityMutationResult(error: .cannotComplete, kind: "select_text", verified: false)
    #expect(uncertain["status"] as? String == "uncertain")
    #expect(uncertain["nativeErrorCode"] as? Int32 == AXError.cannotComplete.rawValue)
    #expect(uncertain["delivered"] is NSNull)
    #expect(throws: BridgeError.self) {
      try bridge.accessibilityMutationResult(error: .illegalArgument, kind: "set_value", verified: false)
    }
  }
  @Test("An opened menu wins over an ambiguous AX return, without requesting a retry")
  func menuActionOutcomes() {
    let opened = computerUseAXOutcome(.cannotComplete, menuOpened: true)
    #expect(opened.status == "delivered")
    #expect(opened.verified)
    #expect(computerUseAXOutcome(.cannotComplete).status == "uncertain")
    #expect(computerUseAXOutcome(.failure).status == "uncertain")
    #expect(computerUseAXOutcome(.actionUnsupported).status == "rejected")
    #expect(computerUseAXOutcome(.invalidUIElement).status == "rejected")
    #expect(!computerUseAXOutcome(.success).verified)
  }

  @Test("Scrolling toward an off-screen element pages in its direction and stops once it overlaps")
  func scrollTowardElement() {
    let visible = CGRect(x: 0, y: 32, width: 300, height: 300)
    #expect(
      computerUseScrollTowardAction(target: CGRect(x: 20, y: 1972, width: 120, height: 40), visible: visible)
        == "AXScrollDownByPage")
    #expect(
      computerUseScrollTowardAction(target: CGRect(x: 20, y: -400, width: 120, height: 40), visible: visible)
        == "AXScrollUpByPage")
    #expect(
      computerUseScrollTowardAction(target: CGRect(x: 900, y: 100, width: 40, height: 40), visible: visible)
        == "AXScrollRightByPage")
    #expect(
      computerUseScrollTowardAction(target: CGRect(x: 20, y: 310, width: 120, height: 40), visible: visible) == nil)
  }

  @Test("Menu shortcuts are reported in pressKey syntax and skip unprintable keys")
  func menuShortcuts() {
    #expect(computerUseMenuShortcut(character: "N", modifiers: 0) == "super+n")
    #expect(computerUseMenuShortcut(character: "N", modifiers: 1) == "super+shift+n")
    #expect(computerUseMenuShortcut(character: "F", modifiers: 4 | 2 | 8) == "ctrl+alt+f")
    #expect(computerUseMenuShortcut(character: "\u{7f}", modifiers: 0) == nil)
    #expect(computerUseMenuShortcut(character: nil, modifiers: 0) == nil)
  }

  @Test("Numeric controls accept numeric strings while text values pass through")
  func numericValues() throws {
    let slider = try computerUseAccessibilityValue("0.25", matching: NSNumber(value: 0.75))
    #expect((slider as? NSNumber)?.doubleValue == 0.25)
    #expect(computerUseAccessibilityValuesMatch(NSNumber(value: 0.25), slider))
    #expect(!computerUseAccessibilityValuesMatch(NSNumber(value: 0.3), slider))
    #expect(try computerUseAccessibilityValue("query", matching: "old" as CFString) as? String == "query")
    #expect(throws: BridgeError.self) { try computerUseAccessibilityValue("loud", matching: NSNumber(value: 1)) }
  }

  @Test("Observations retain action names while omitting internal Objective-C details")
  func cleanActionNames() {
    #expect(computerUseActionLabel("Name:More\nTarget:0x0\nSelector:(null)") == "More")
    #expect(computerUseActionLabel("AXPress") == "AXPress")
  }

  @Test("A follow-up observation reports changed, added and removed elements by their stable indexes")
  func observationDifferences() {
    let old = [
      "4 AXMenu Add", "  5 AXMenuItem New Playlist", "  6 AXMenuItem Chill", "  7 AXMenuItem Pool",
      "  9 AXMenuItem Dance", "… 3 more rows not shown",
    ].joined(separator: "\n")
    let new = [
      "4 AXMenu Add", "  5 AXMenuItem New Playlist Selected", "  8 AXMenuItem agents only (codevisor)",
      "… 3 more rows not shown",
    ].joined(separator: "\n")
    #expect(
      computerUseObservationText(current: new, previous: old)
        == [
          computerUseDiffHeader, "Removed element IDs: 6-7, 9", "~   5 AXMenuItem New Playlist Selected",
          "+   8 AXMenuItem agents only (codevisor)",
        ].joined(separator: "\n"))
    #expect(computerUseObservationText(current: new, previous: new) == "No changes since the previous observation.")
    #expect(computerUseObservationText(current: new, previous: nil) == new)
  }

  @Test("App and window references survive switching targets without crossing scopes")
  func snapshotScopes() throws {
    let bridge = ComputerUseBridge()
    let first = ComputerUseBridge.SnapshotRecord(
      elements: [:], pid: 100, windowID: 1,
      windowFrame: .zero, screenshotPixelSize: nil, createdAt: 1, text: "first", view: "window")
    let second = ComputerUseBridge.SnapshotRecord(
      elements: [:], pid: 200, windowID: 2,
      windowFrame: .zero, screenshotPixelSize: nil, createdAt: 2, text: "second", view: "window")
    bridge.snapshots["session"] = ["one": first, "two": second]
    bridge.latestSnapshotIDs[computerUseSnapshotScope("session", 100, 1)] = "one"
    bridge.latestSnapshotIDs[computerUseSnapshotScope("session", 200, 2)] = "two"
    #expect(try bridge.currentSnapshot(sessionID: "session", pid: 100, windowID: 1, arguments: [:]).text == "first")
    #expect(throws: BridgeError.self) {
      try bridge.currentSnapshot(sessionID: "session", pid: 100, windowID: 1, arguments: ["snapshot_id": "two"])
    }
    #expect(throws: BridgeError.self) {
      try bridge.currentSnapshot(sessionID: "session", pid: 100, windowID: 2, arguments: [:])
    }
    bridge.latestSnapshotIDs[computerUseSnapshotScope("session", 100, 1)] = "new"
    #expect(throws: BridgeError.self) {
      try bridge.currentSnapshot(sessionID: "session", pid: 100, windowID: 1, arguments: ["snapshot_id": "one"])
    }
  }

  @Test("Window movement and resizing invalidate a screenshot coordinate mapping")
  func movedWindowGeometry() {
    let original = CGRect(x: 691, y: 80, width: 1229, height: 949)
    #expect(computerUseFramesMatch(original, original))
    #expect(!computerUseFramesMatch(original, CGRect(x: 447, y: 1113, width: 1229, height: 949)))
    #expect(!computerUseFramesMatch(original, CGRect(x: 691, y: 80, width: 1200, height: 949)))
  }

  @Test("Function keys, keypad keys and complete sequences can be validated before sending input")
  func keyValidation() throws {
    let bridge = ComputerUseBridge()
    for key in ["Down", "Right", "Return", "super+a", "KP_0", "KP_Enter", "F1", "F12"] {
      try bridge.validateKey(key)
    }
    #expect(throws: BridgeError.self) { try bridge.validateKey("super+imaginary") }
    #expect(throws: BridgeError.self) { try bridge.validateKey("imaginary+a") }
    #expect(try bridge.keyStroke("KP_0").code == 82)
    #expect(try bridge.keyStroke("A").flags.contains(.maskShift))
  }

  @Test("Pasting never overwrites a clipboard change made by the user")
  func clipboardOwnership() {
    #expect(computerUseShouldRestoreClipboard(writtenChangeCount: 10, currentChangeCount: 10))
    #expect(!computerUseShouldRestoreClipboard(writtenChangeCount: 10, currentChangeCount: 11))
  }
}
