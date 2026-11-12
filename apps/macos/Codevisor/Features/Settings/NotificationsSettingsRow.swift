import SwiftUI
import UserNotifications

struct NotificationsSettingsRow: View {
  @State private var status: UNAuthorizationStatus?

  var body: some View {
    PermissionRow(
      symbol: "bell.badge",
      title: "Notifications",
      subtitle: "Chat alerts when an agent finishes or needs your input",
      grantedLabel: isGranted ? "Granted" : nil,
      embedded: true
    ) {
      switch status {
      case .notDetermined:
        PermissionActionButton("Grant", action: request)
      case .denied:
        PermissionActionButton("Open System Settings") {
          ChatNotificationManager.shared.openSystemNotificationSettings()
        }
      default:
        EmptyView()
      }
    }
    .modifier(PermissionPolling(refresh: refresh))
  }

  private var isGranted: Bool {
    status == .authorized || status == .provisional
  }

  private func request() {
    Task {
      await ChatNotificationManager.shared.requestAuthorization()
      await refresh()
    }
  }

  private func refresh() async {
    status = await ChatNotificationManager.shared.authorizationStatus()
  }
}
