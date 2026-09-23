import CodevisorCore
import CodevisorUI
import SwiftUI

/// Presentations that must cover the whole window regardless of container:
/// on the split layout a cover attached inside the sidebar column would only
/// cover that column, so these sit above the container switch. The New Chat
/// sheet is deliberately not here — it is compact-only and lives in
/// `stackContainer` with its zoom transition source.
extension HomeView {
  /// Requests posted app-wide (a transcript row asking for sign-in) come
  /// from the window the user just touched, which is the key window. Every
  /// other iPad window ignores them. With no key window at all, answer.
  var isWorkingWindow: Bool {
    guard let window = hostWindow.window else { return true }
    if window.isKeyWindow { return true }
    let anyKeyWindow = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .contains { $0.windows.contains(where: \.isKeyWindow) }
    return !anyKeyWindow
  }

  func hoistedPresentations<Content: View>(_ content: Content) -> some View {
    content
      .modifier(
        HomeSidebarAlerts(
          renamingWorkspace: $renamingWorkspace,
          workspaceRenameTitle: $workspaceRenameTitle,
          renamingTab: $renamingTab,
          tabRenameTitle: $tabRenameTitle,
          onRenameWorkspace: { renameWorkspace($0) },
          onRenameTab: { renameSidebarTab($0, to: $1) }
        )
      )
      .sheet(item: $presentedSettingsDestination, onDismiss: { clientPresentationCompletion.complete("settings") }) {
        destination in
        SettingsSheet(initialDestination: destination, onSectionChange: { clientSettingsSection = $0 })
          .id(destination.id)
      }
      .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenSettings)) { _ in
        guard isWorkingWindow else { return }
        presentedSettingsDestination = .root
      }
      .harnessSignInSheet(request: $pendingHarnessSignIn)
      .onReceive(NotificationCenter.default.publisher(for: .codevisorHarnessSignIn)) {
        notification in
        guard isWorkingWindow else { return }
        pendingHarnessSignIn = HarnessSignInRequest(notification: notification)
      }
      .fullScreenCover(isPresented: showsOnboarding) {
        onboardingStart = .welcome
      } content: {
        OnboardingView(start: hasRemoteMachines || onboardingDismissed ? .connect : onboardingStart)
          .interactiveDismissDisabled(!hasAIDataSharingConsent)
          // The QR flow lands here: alerts must present over the
          // cover, so it carries its own copy of the deeplink
          // alerts, active while it is the visible context.
          .modifier(
            MachineDeeplinkAlerts(
              pending: $pendingDeeplink,
              error: $deeplinkError,
              isActive: true
            )
          )
      }
      // Parse and route codevisor:// deeplinks in one modifier;
      // diagnostic chat opens come back through these closures.
      .modifier(
        HomeExternalRouting(
          pendingDeeplink: $pendingDeeplink,
          pendingPluginInstall: $pendingPluginInstall,
          openDiagnosticSession: { id in
            #if DEBUG || NAVIGATION_DIAGNOSTICS
              openDiagnosticSession(id)
            #endif
          },
          openDiagnosticNewChat: { text in
            #if DEBUG || NAVIGATION_DIAGNOSTICS
              presentDiagnosticNewChat(text: text)
            #endif
          }
        )
      )
      .modifier(
        MachineDeeplinkAlerts(
          pending: $pendingDeeplink,
          error: $deeplinkError,
          isActive: !showsOnboarding.wrappedValue
        )
      )
      .task {
        try? await Task.sleep(for: .milliseconds(300))
        readyForOnboarding = true
        #if DEBUG || NAVIGATION_DIAGNOSTICS
          await handleDiagnosticSessionLaunchIfNeeded()
          await handleDiagnosticNewChatLaunchIfNeeded()
        #endif
      }
  }
}
