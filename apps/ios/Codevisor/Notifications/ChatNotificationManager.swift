import CodevisorCore
import SwiftUI
import UserNotifications
import os

// ChatAttentionKind, ChatAttentionEvent, and ChatNotificationDelivering live
// in CodevisorCore (Notifications/ChatAttentionEvent.swift); this file is the iOS
// delivery. With every machine's event stream connected in the background,
// an agent finishing ANYWHERE surfaces here — as a banner while the user is
// elsewhere in the app, and as a system notification for the brief window
// iOS keeps the sockets alive after backgrounding. (True closed-app push
// needs APNs through the cloud hub — a later phase.)

extension Notification.Name {
    static let codevisorOpenChatNotification = Notification.Name("CodevisorOpenChatNotification")
}

@MainActor
final class ChatNotificationManager: NSObject, ChatNotificationDelivering,
    UNUserNotificationCenterDelegate
{
    static let shared = ChatNotificationManager()

    private static let sessionIdKey = "sessionId"
    private static let serverIdKey = "serverId"

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Codevisor",
        category: "ChatNotifications"
    )
    private weak var settingsModel: AppSettingsModel?

    override private init() {
        super.init()
        center.delegate = self
    }

    func configure(settings: AppSettingsModel) {
        settingsModel = settings
        center.delegate = self
    }

    func prepareAuthorizationIfNeeded() async {
        guard let settings = settingsModel?.settings,
            settings.notificationsEnabled,
            settings.systemNotificationsEnabled
        else { return }
        let current = await center.notificationSettings()
        guard current.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(_ event: ChatAttentionEvent) {
        guard let settings = settingsModel?.settings, settings.notificationsEnabled else { return }
        clearNotifications(for: event.sessionId)
        Task { await schedule(event, settings: settings) }
    }

    func clearNotifications(for sessionId: UUID) {
        let identifiers = ChatAttentionKind.allCases.map {
            notificationIdentifier(sessionId: sessionId, kind: $0)
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func schedule(_ event: ChatAttentionEvent, settings: AppSettings) async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = event.kind.notificationTitle
        content.body = event.sessionTitle.isEmpty ? "Chat" : event.sessionTitle
        content.threadIdentifier = "chat.\(event.sessionId.uuidString)"
        content.targetContentIdentifier = event.sessionId.uuidString
        content.interruptionLevel = .active
        content.userInfo = [
            Self.sessionIdKey: event.sessionId.uuidString,
            Self.serverIdKey: event.serverId,
        ]
        if settings.notificationSoundsEnabled {
            content.sound = .default
        }
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: notificationIdentifier(sessionId: event.sessionId, kind: event.kind),
                    content: content,
                    trigger: nil
                ))
        } catch {
            log.error(
                "Scheduling chat notification failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func notificationIdentifier(sessionId: UUID, kind: ChatAttentionKind) -> String {
        "codevisor.chat.\(sessionId.uuidString).\(kind.rawValue)"
    }

    // The coordinator never delivers for the focused chat, so an in-app
    // banner always concerns a chat (often a machine) the user is not
    // looking at — exactly when it is useful.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[Self.sessionIdKey] as? String,
            UUID(uuidString: raw) != nil,
            let serverId = info[Self.serverIdKey] as? String
        else { return }
        NotificationCenter.default.post(
            name: .codevisorOpenChatNotification,
            object: nil,
            userInfo: [Self.sessionIdKey: raw, Self.serverIdKey: serverId]
        )
    }
}
