#if os(iOS)
  import XCTest

  @MainActor
  final class ComposerExpandTests: XCTestCase {
    private static let rounds = 3
    private static let swipeDistance: CGFloat = 320
    private static let settleTimeout: TimeInterval = 10
    private static let pressDuration: TimeInterval = 0.05
    private static let editorGrabInset: CGFloat = 20
    private static let toolbarGrabOffset: CGFloat = 22

    private var app: XCUIApplication!

    override func setUp() async throws {
      continueAfterFailure = false
      XCUIDevice.shared.orientation = .portrait
      app = XCUIApplication()
      app.launchEnvironment["CODEVISOR_APP_STORE_SCREENSHOTS"] = "1"
      app.launchEnvironment["CODEVISOR_SCREENSHOT_SCENE"] = "conversation"
      app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
      app.launch()
      XCTAssertTrue(composer.waitForExistence(timeout: 30))
    }

    override func tearDown() async throws {
      app.terminate()
    }

    func testSwipingTheToolbarExpandsAndCollapsesTheComposerAboveTheKeyboard() {
      focusComposer()
      for _ in 0..<Self.rounds {
        swipe(from: toolbarPoint, by: -Self.swipeDistance)
        awaitComposer(expanded: true)
        swipe(from: toolbarPoint, by: Self.swipeDistance)
        awaitComposer(expanded: false)
      }
    }

    func testSwipingTheEditorExpandsAndCollapsesTheComposerAboveTheKeyboard() {
      focusComposer()
      for _ in 0..<Self.rounds {
        swipe(from: editorPoint, by: -Self.swipeDistance)
        awaitComposer(expanded: true)
        swipe(from: editorPoint, by: Self.swipeDistance)
        awaitComposer(expanded: false)
      }
    }

    private func focusComposer() {
      editorPoint.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.settleTimeout))
      app.typeText("Hello")
    }

    private var composer: XCUIElement {
      app.textViews.firstMatch
    }

    private var origin: XCUICoordinate {
      app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
    }

    private var editorPoint: XCUICoordinate {
      let frame = composer.frame
      return origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + Self.editorGrabInset))
    }

    private var toolbarPoint: XCUICoordinate {
      let frame = composer.frame
      return origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY + Self.toolbarGrabOffset))
    }

    private func swipe(from start: XCUICoordinate, by distance: CGFloat) {
      start.press(forDuration: Self.pressDuration, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
    }

    private func awaitComposer(expanded: Bool) {
      let windowHeight = app.windows.firstMatch.frame.height
      let reachesTop = NSPredicate { element, _ in
        guard let element = element as? XCUIElement else { return false }
        return (element.frame.minY < windowHeight / 3) == expanded
      }
      let settled = XCTNSPredicateExpectation(predicate: reachesTop, object: composer)
      XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: Self.settleTimeout), .completed)
    }
  }
#endif
