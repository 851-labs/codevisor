import CoreGraphics
import Testing
@testable import CodevisorCoreMac

@MainActor
@Suite("Computer Use window visibility")
struct ComputerUseWindowVisibilityTests {
  @Test(
    "Names why a window is out of sight, preferring what the human did to the app",
    arguments: [
      (WindowFacts(isOnScreen: nil), ComputerUseWindowVisibility.closed),
      (WindowFacts(isOnScreen: true, minimized: true), .visible),
      (WindowFacts(appHidden: true, minimized: true, onSpace: true), .appHidden),
      (WindowFacts(minimized: true, onSpace: true), .minimized),
      (WindowFacts(onSpace: true), .otherSpace),
      (WindowFacts(), .closed),
    ])
  func classify(facts: WindowFacts, expected: ComputerUseWindowVisibility) {
    let visibility = ComputerUseWindowVisibility.classify(
      isOnScreen: facts.isOnScreen,
      appIsHidden: { facts.appHidden },
      isMinimized: { facts.minimized },
      isOnAnySpace: { facts.onSpace })
    #expect(visibility == expected)
  }

  @Test("Reads accessibility only when the window's on-screen state changes, and reports its return")
  func monitor() {
    let fake = FakeWindowServer()
    let monitor = ComputerUseWindowVisibilityMonitor(dependencies: fake.dependencies)
    let target = ComputerUseWindowVisibilityMonitor.Target(pid: 42, windowID: 7)

    #expect(monitor.read(["s": target])["s"] == .init(visibility: .visible, becameVisible: false))
    fake.isOnScreen = false
    fake.minimized = true
    #expect(monitor.read(["s": target])["s"] == .init(visibility: .minimized, becameVisible: false))
    #expect(monitor.read(["s": target])["s"] == .init(visibility: .minimized, becameVisible: false))
    #expect(fake.minimizedReads == 1)

    fake.isOnScreen = true
    #expect(monitor.read(["s": target])["s"] == .init(visibility: .visible, becameVisible: true))
    #expect(monitor.read(["s": target])["s"] == .init(visibility: .visible, becameVisible: false))
    #expect(fake.minimizedReads == 1)
  }
}

struct WindowFacts: Sendable, CustomTestStringConvertible {
  var isOnScreen: Bool? = false
  var appHidden = false
  var minimized = false
  var onSpace = false

  var testDescription: String {
    "onScreen=\(isOnScreen.map(String.init) ?? "unlisted") hidden=\(appHidden) minimized=\(minimized) onSpace=\(onSpace)"
  }
}

@MainActor
private final class FakeWindowServer {
  var isOnScreen = true
  var minimized = false
  var minimizedReads = 0

  var dependencies: ComputerUseWindowVisibilityMonitor.Dependencies {
    .init(
      isOnScreen: { [unowned self] _ in isOnScreen },
      appIsHidden: { _ in false },
      isMinimized: { [unowned self] _ in
        minimizedReads += 1
        return minimized
      },
      isOnAnySpace: { _ in true })
  }
}
