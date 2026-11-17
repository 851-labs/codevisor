import CodevisorClient
import SwiftUI
import TranscriptKit

struct TabSwitchBenchSteps: ViewModifier {
  let store: SessionStore?
  let window: ClientWindowControl
  @State private var observers: [DarwinNotificationObserver] = []

  func body(content: Content) -> some View {
    content.task(id: store.map(ObjectIdentifier.init)) {
      observers = []
      guard TranscriptPerformanceTrace.isEnabled, let store else { return }

      observers = [("previous", -1), ("next", 1)].map { direction, offset in
        DarwinNotificationObserver(Self.notificationName(direction)) { [weak store] in
          guard let store, window.window == (NSApp.keyWindow ?? NSApp.mainWindow) else { return }

          store.workspaceStepHandler?(offset)
        }
      }
    }
  }

  static func notificationName(_ direction: String) -> String {
    "com.851labs.codevisor.dev.tab-step.\(CodevisorAppVariant.developmentWorktreeName).\(direction)"
  }
}
