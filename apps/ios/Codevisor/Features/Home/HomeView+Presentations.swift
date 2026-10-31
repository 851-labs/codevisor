import CodevisorCore
import CodevisorUI
import SwiftUI

extension HomeView {
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
      .botManagement(
        editing: $botEditor, deleting: $deletingBot,
        onCreated: { openBot($0) }, onArchive: { setBotArchived($0, true) }, onDeleted: { closeBot($0) }
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
        OnboardingView(
          start: hasRemoteMachines || onboardingDismissed || needsLocalNetworkStep ? .connect : onboardingStart
        )
        .interactiveDismissDisabled(!hasAIDataSharingConsent || needsLocalNetworkStep)
        .modifier(CloudDeviceApprovalPresentation(pending: $pendingDeviceApproval, hostedByOnboarding: true))
      }
      .modifier(
        HomeExternalRouting(
          pendingDeviceApproval: $pendingDeviceApproval,
          isOnboardingPresented: showsOnboarding.wrappedValue,
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
      .modifier(CloudDeviceApprovalPresentation(pending: $pendingDeviceApproval, hostedByOnboarding: false))
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
