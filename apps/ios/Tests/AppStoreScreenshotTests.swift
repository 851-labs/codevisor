import XCTest

/// Invoked by screenshots-ios.mjs, opt-in so ordinary UI test runs don't export assets.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
  func testCaptureScreenshots() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEVISOR_CAPTURE_SCREENSHOTS"] == "1")
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    for (scene, name, marker) in [
      ("projects", "01-projects", "portfolio"),
      ("conversation", "02-conversation", "The focus timer is ready to try."),
      ("new-chat", "03-new-chat", "portfolio"),
      ("browser", "04-browser", "Start focus"),
    ] {
      let app = XCUIApplication()
      app.launchEnvironment["CODEVISOR_APP_STORE_SCREENSHOTS"] = "1"
      app.launchEnvironment["CODEVISOR_SIDEBAR_SAMPLE"] = "1"
      app.launchEnvironment["CODEVISOR_SCREENSHOT_SCENE"] = scene
      app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
      app.launch()
      defer { app.terminate() }
      let content = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker))
        .firstMatch
      XCTAssertTrue(content.waitForExistence(timeout: 30), "Missing screenshot content: \(scene)")
      if scene == "new-chat" {
        app.buttons["New chat"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let machinePicker = app.buttons["newChat.machinePicker"]
        XCTAssertTrue(machinePicker.waitForExistence(timeout: 10))
        XCTAssertEqual(machinePicker.value as? String, "Studio Mac")
        XCTAssertEqual(app.buttons["newChat.projectPicker"].value as? String, "daylight")
        XCTAssertEqual(app.buttons["Model"].value as? String, "Sonnet 4.6")
        XCTAssertFalse(app.buttons["Continue"].exists, "Keyboard tutorial must not cover the capture")
      } else {
        XCTAssertEqual(app.keyboards.count, 0)
      }
      let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      screenshot.name = name
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
  }
}
