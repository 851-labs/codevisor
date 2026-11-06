import AppKit
import CodevisorCore
import SwiftUI

@MainActor
final class FloatingPaneWindows {
  static let shared = FloatingPaneWindows()

  private var presentations: [FloatingPaneKey: FloatingPanePresentation] = [:]

  func focus(for key: FloatingPaneKey) -> TerminalFocusController? {
    presentations[key]?.focus
  }

  func isKey(_ key: FloatingPaneKey) -> Bool {
    presentations[key]?.panel.isKeyWindow == true
  }

  func isPresented(_ key: FloatingPaneKey, by owner: UUID) -> Bool {
    presentations[key]?.owner == owner
  }

  func present(_ request: FloatingPaneRequest, content: (TerminalFocusController) -> some View) {
    dismiss(request.key)
    let presentation = FloatingPanePresentation(request, cascadeIndex: presentations.count)
    presentations[request.key] = presentation
    presentation.show(content(presentation.focus))
  }

  func raise(_ key: FloatingPaneKey) {
    presentations[key]?.panel.makeKeyAndOrderFront(nil)
  }

  func dismiss(_ key: FloatingPaneKey) {
    presentations.removeValue(forKey: key)?.close()
  }

  func dismiss(in workspaceId: UUID, keeping kept: Set<UUID>, by owner: UUID) {
    let dismissed = presentations.filter { key, presentation in
      key.workspaceId == workspaceId && presentation.owner == owner && !kept.contains(key.leafId)
    }
    dismissed.keys.forEach(dismiss)
  }
}
