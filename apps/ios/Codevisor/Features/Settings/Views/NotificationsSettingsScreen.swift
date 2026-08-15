import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Notifications

struct NotificationsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            Section {
                Toggle(
                    "Chat notifications",
                    isOn: Binding(
                        get: { environment.settings.settings.notificationsEnabled },
                        set: { environment.settings.setNotificationsEnabled($0) }
                    )
                )
            } footer: {
                Text("Get notified when a chat finishes or needs your input.")
            }
            Section("Delivery") {
                Toggle(
                    "Show notifications when Codevisor isn't active",
                    isOn: Binding(
                        get: { environment.settings.settings.systemNotificationsEnabled },
                        set: { environment.settings.setSystemNotificationsEnabled($0) }
                    )
                )
                if authorization == .notDetermined {
                    Button("Allow System Notifications…") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge])
                            await refreshAuthorization()
                        }
                    }
                } else if authorization == .denied {
                    Button("Open Notification Settings…") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            Section("Sounds") {
                Toggle(
                    "Play sounds",
                    isOn: Binding(
                        get: { environment.settings.settings.notificationSoundsEnabled },
                        set: { environment.settings.setNotificationSoundsEnabled($0) }
                    )
                )
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAuthorization() }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }
}
