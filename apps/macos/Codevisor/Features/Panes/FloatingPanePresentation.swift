import AppKit
import CodevisorCore
import SwiftUI

@MainActor
final class FloatingPanePresentation: NSObject, NSWindowDelegate {
  private static let screenInset: CGFloat = 24
  private static let toolbarClearance: CGFloat = 64
  private static let cascadeStep: CGFloat = 28

  let focus = TerminalFocusController()
  let panel = FloatingPanePanel()
  private let request: FloatingPaneRequest
  private let cascadeIndex: Int

  var owner: UUID { request.owner }

  init(_ request: FloatingPaneRequest, cascadeIndex: Int) {
    self.request = request
    self.cascadeIndex = cascadeIndex
    super.init()
    panel.delegate = self
  }

  func show(_ content: some View) {
    let host = NSHostingController(rootView: content)
    host.sceneBridgingOptions = [.title, .toolbars]
    panel.contentViewController = host
    panel.initialFirstResponder = host.view
    place()
    if request.activating {
      panel.makeKeyAndOrderFront(nil)
    } else {
      panel.orderFront(nil)
    }
    publishAttention()
  }

  func close() {
    request.attention.clear(owner: ObjectIdentifier(self))
    panel.delegate = nil
    panel.close()
    panel.contentViewController = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    request.onClose()
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) {
    publishAttention()
  }

  func windowDidResignKey(_ notification: Notification) {
    publishAttention()
  }

  private func publishAttention() {
    request.attention.publish(owner: ObjectIdentifier(self), isKey: panel.isKeyWindow)
  }

  private var frameName: String {
    "FloatingPane.\(request.key.leafId.uuidString)"
  }

  private func place() {
    panel.resetSize()
    if !panel.setFrameUsingName(frameName) {
      panel.setFrameTopLeftPoint(defaultTopLeft)
    }
    panel.setFrameAutosaveName(frameName)
  }

  private var defaultTopLeft: NSPoint {
    let anchor = NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
    let cascade = CGFloat(cascadeIndex) * Self.cascadeStep
    return NSPoint(
      x: anchor.maxX - panel.frame.width - Self.screenInset - cascade,
      y: anchor.maxY - Self.toolbarClearance - cascade
    )
  }
}
