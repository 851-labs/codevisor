import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use observation labels")
struct ComputerUseObservationLabelTests {
  @Test("A row is labeled by its first worded text, not a track number or duration")
  func rowLabelPrefersWords() {
    var row = ComputerUseSubtreeText()
    for text in ["19", "Hedwig's Theme", "5:09", "John Williams"] { row.absorb(ComputerUseSubtreeText(text)) }
    #expect(row.best == "Hedwig's Theme")

    var numbersOnly = ComputerUseSubtreeText("19")
    numbersOnly.absorb(ComputerUseSubtreeText("5:09"))
    #expect(numbersOnly.best == "19")
    #expect(ComputerUseSubtreeText().best == nil)
  }

  @Test("Observations settle for a short window after this session's last action")
  func settleWindow() {
    #expect(computerUseSettleWindow(sinceAction: nil) == 0)
    #expect(computerUseSettleWindow(sinceAction: 0) == 1.5)
    #expect(computerUseSettleWindow(sinceAction: 1) == 0.5)
    #expect(computerUseSettleWindow(sinceAction: 2) == 0)
  }

  @Test("Hover-only actions are hidden from observations")
  func hiddenActions() {
    #expect(computerUseHiddenAction("AXShowAlternateUI"))
    #expect(computerUseHiddenAction("AXShowDefaultUI"))
    #expect(!computerUseHiddenAction("AXShowMenu"))
  }

  @Test("A redrawn element is matched to the same-identity element nearest where it was")
  func closestCandidate() {
    let old = CGRect(x: 100, y: 100, width: 40, height: 20)
    let near = CGRect(x: 104, y: 98, width: 40, height: 20)
    let far = CGRect(x: 600, y: 400, width: 40, height: 20)
    #expect(computerUseClosestCandidate(to: old, among: [far, near]) == 1)
    #expect(computerUseClosestCandidate(to: nil, among: [far]) == 0)
    #expect(computerUseClosestCandidate(to: nil, among: [far, near]) == nil)
    #expect(computerUseClosestCandidate(to: old, among: [nil, nil]) == nil)
    #expect(computerUseClosestCandidate(to: old, among: []) == nil)
  }

  @Test("Sheets, alerts and modal windows are followed as dialogs; ordinary windows are not")
  func dialogWindows() {
    #expect(computerUseIsDialogWindow(role: "AXSheet", subrole: nil, modal: false))
    #expect(computerUseIsDialogWindow(role: "AXWindow", subrole: "AXDialog", modal: false))
    #expect(computerUseIsDialogWindow(role: "AXWindow", subrole: "AXSystemDialog", modal: false))
    #expect(computerUseIsDialogWindow(role: "AXWindow", subrole: "AXStandardWindow", modal: true))
    #expect(!computerUseIsDialogWindow(role: "AXWindow", subrole: "AXStandardWindow", modal: false))
  }
}
