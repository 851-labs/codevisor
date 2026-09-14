import XCTest

@MainActor
final class SidebarNavigationTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchEnvironment["CODEVISOR_SIDEBAR_SAMPLE"] = "1"
    app.launch()
    XCTAssertTrue(app.staticTexts["landing-refresh"].waitForExistence(timeout: 10))
  }

  override func tearDown() async throws {
    app.terminate()
    app = nil
  }

  func testScrollStartingOnWorkspaceName() {
    assertScroll(from: app.staticTexts["landing-refresh"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
  }

  func testScrollStartingOnHeaderWhitespace() {
    let name = app.staticTexts["landing-refresh"]
    let point = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: app.frame.width - 70, dy: name.frame.midY
      ))
    assertScroll(from: point)
  }

  func testScrollStartingOnHeaderMenu() {
    assertScroll(
      from: app.buttons["landing-refresh actions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
  }

  func testScrollStartingOnTabRow() {
    assertScroll(
      from: row("Add dark mode support").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
  }

  func testLongPressStillReordersAndReleasesScrolling() {
    let start = app.staticTexts["codevisor"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
    start.press(forDuration: 0.5, thenDragTo: destination)
    let sidebar = app.descendants(matching: .any).matching(identifier: "sample-sidebar").firstMatch
    let reordered = NSPredicate { _, _ in
      (sidebar.value as? String) == "landing-refresh,api,scratch,codevisor"
    }
    expectation(for: reordered, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
    // Rows return after the drop, and subsequent swipes work again.
    XCTAssertTrue(row("Refresh landing page copy").waitForExistence(timeout: 5))
    assertScroll(
      from: row("Refresh landing page copy").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
      markerName: "api")
  }

  private func row(_ title: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  private func assertScroll(
    from start: XCUICoordinate, markerName: String = "landing-refresh",
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let sidebar = app.descendants(matching: .any).matching(identifier: "sample-sidebar").firstMatch
    let order = sidebar.value as? String
    let marker = app.staticTexts[markerName]
    let before = marker.frame.minY
    XCTAssertGreaterThan(before, 0, file: file, line: line)
    let end = start.withOffset(CGVector(dx: 0, dy: -140))
    start.press(forDuration: 0, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    let scrolled = NSPredicate { _, _ in marker.exists && marker.frame.minY < before - 40 }
    expectation(for: scrolled, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
    // A swipe never changes workspace order.
    XCTAssertEqual(sidebar.value as? String, order, file: file, line: line)
  }
}
