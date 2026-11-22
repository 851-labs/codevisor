import CodevisorCore
import SwiftUI

struct GitRequiredSheet: View {
  @State private var install = GitInstallProgress.notStarted

  var body: some View {
    VStack(spacing: 20) {
      GitRequiredHeader()
      VStack(spacing: 12) {
        Button("Install", action: openInstaller)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .controlSize(.large)
          .disabled(install == .opening)
        GitInstallStatus(install: install)
      }
    }
    .padding(24)
    .frame(width: 420)
    .animation(.snappy(duration: 0.2), value: install)
    .interactiveDismissDisabled()
    .onAppear { captureStep("shown") }
    .onDisappear { captureStep("resolved") }
  }

  private func openInstaller() {
    install = .opening
    Task {
      let failure = await AppleDeveloperToolsInstaller.open()
      install = failure.map(GitInstallProgress.failed) ?? .waiting
      captureStep(failure == nil ? "installer_opened" : "installer_failed")
    }
  }

  private func captureStep(_ step: String) {
    Analytics.capture(.gitSetup, properties: ["step": .string(step)])
  }
}
