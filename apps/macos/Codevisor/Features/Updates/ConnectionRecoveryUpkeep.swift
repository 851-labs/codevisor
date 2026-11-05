import AppKit
import CodevisorCore
import SwiftUI

struct ConnectionRecoveryUpkeep: ViewModifier {
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content
      .onChange(of: environment.networkPath.recoveryToken) { _, _ in recover() }
      .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
        recover()
      }
  }

  private func recover() {
    guard !AppPreview.isRunning else { return }

    Task { await environment.recoverConnections() }
  }
}
