import Testing

@testable import CodevisorUI

@MainActor
struct SavedInspectorColumnTests {
  @MainActor
  final class Setting {
    var isShown: Bool
    var closes = 0
    var reverts = 0
    var settles = 0

    init(isShown: Bool) {
      self.isShown = isShown
    }

    func column() -> SavedInspectorColumn {
      SavedInspectorColumn(
        isShown: isShown, savedIsShown: { self.isShown },
        close: {
          self.closes += 1
          self.isShown = false
        },
        revert: { self.reverts += 1 },
        settle: { self.settles += 1 })
    }
  }

  @Test("Dragging the shown column closed saves it closed")
  func dragClosingSavesClosed() {
    let setting = Setting(isShown: true)

    setting.column().binding.wrappedValue = false

    #expect(!setting.isShown)
    #expect(setting.closes == 1)
    #expect(setting.reverts == 0)
  }

  @Test("A column that expands on its own is reverted and the setting stays closed")
  func unrequestedExpandIsReverted() {
    let setting = Setting(isShown: false)

    setting.column().binding.wrappedValue = true

    #expect(!setting.isShown)
    #expect(setting.reverts == 1)
    #expect(setting.closes == 0)
  }

  @Test(
    "A late report of the toggle's own change only settles, even through a binding built before it",
    arguments: [true, false])
  func lateReportOfToggleOnlySettles(toggledTo shown: Bool) {
    let setting = Setting(isShown: !shown)
    let earlier = setting.column().binding

    setting.isShown = shown
    earlier.wrappedValue = shown

    #expect(setting.isShown == shown)
    #expect(setting.closes == 0)
    #expect(setting.reverts == 0)
    #expect(setting.settles == 1)
  }
}
