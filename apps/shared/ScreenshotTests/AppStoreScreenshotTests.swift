import XCTest
#if os(macOS)
  import AppKit
#endif

/// Both capture scripts use these scenes and readiness checks. Ordinary test runs skip capture.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
  func testCaptureScreenshots() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEVISOR_CAPTURE_SCREENSHOTS"] == "1")
    continueAfterFailure = false
    #if os(iOS)
      XCUIDevice.shared.orientation = .portrait
    #endif
    let appearance = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_APPEARANCE"] ?? "light"
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
      app.launchEnvironment["CODEVISOR_SCREENSHOT_APPEARANCE"] = appearance
      app.launchArguments = [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
      ]
      #if os(macOS)
        // The offline demo never needs real credentials. Rebuilt ad-hoc apps
        // otherwise wait for Keychain authorization during Chromium shutdown.
        app.launchArguments.append("--use-mock-keychain")
      #endif
      app.launch()
      defer { app.terminate() }
      // AppKit's transcript exposes its text as a value; UIKit uses labels.
      let content: XCUIElement
      #if os(macOS)
        if scene == "conversation" {
          content = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        } else if scene == "browser" {
          content = app.buttons.matching(NSPredicate(format: "title == %@", marker)).firstMatch
        } else {
          content =
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        }
      #else
        content = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
      #endif
      XCTAssertTrue(content.waitForExistence(timeout: 30), "Missing screenshot content: \(scene)")
      #if os(iOS)
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
      #else
        let window = app.windows["marketing-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 1280)
        XCTAssertEqual(window.frame.height, 820)
        if scene == "new-chat" || scene == "projects" {
          XCTAssertTrue(app.buttons["Model"].waitForExistence(timeout: 10))
        }
        app.activate()
        let screenshot = try await captureWindow(window)
      #endif
      screenshot.name = name
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
  }

  #if os(macOS)
    /// XCTest's screenshot() crops the desktop and can include overlapping windows.
    /// The CLI captures that window by ID, with transparent corners and no shadow.
    private func captureWindow(_ element: XCUIElement) async throws -> XCTAttachment {
      let bundle = try XCTUnwrap(ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_BUNDLE_IDENTIFIER"])
      let application = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first)
      let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
      let window = try XCTUnwrap(
        windows.first {
          guard $0[kCGWindowOwnerPID as String] as? pid_t == application.processIdentifier,
            let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds)
          else { return false }
          return frame.size == element.frame.size
        }, "Could not find the Codevisor screenshot window")
      let windowId = try XCTUnwrap(window[kCGWindowNumber as String] as? Int)
      let address = try XCTUnwrap(ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_CAPTURE_URL"])
      var request = URLRequest(url: try XCTUnwrap(URL(string: address)), timeoutInterval: 30)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["windowId": windowId])
      let (data, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual(
        (response as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "Capture failed")
      return XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    }
  #endif
}
