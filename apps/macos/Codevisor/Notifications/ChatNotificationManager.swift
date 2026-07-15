import AppKit
import CodevisorCore
import os
import UserNotifications

enum ChatAttentionKind: String, Sendable {
    case finished
    case actionRequired

    var notificationTitle: String {
        switch self {
        case .finished: "Chat finished"
        case .actionRequired: "Action required"
        }
    }
}

struct ChatAttentionEvent: Sendable {
    let id: UUID
    let sessionId: UUID
    let serverId: String
    let sessionTitle: String
    let kind: ChatAttentionKind

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        serverId: String,
        sessionTitle: String,
        kind: ChatAttentionKind
    ) {
        self.id = id
        self.sessionId = sessionId
        self.serverId = serverId
        self.sessionTitle = sessionTitle
        self.kind = kind
    }
}

@MainActor
protocol ChatNotificationDelivering: AnyObject {
    func deliver(_ event: ChatAttentionEvent, sessionIsOpen: Bool)
    func clearNotifications(for sessionId: UUID)
}

extension Notification.Name {
    static let codevisorOpenChatNotification = Notification.Name("CodevisorOpenChatNotification")
}

struct SystemSoundChoice: Identifiable, Hashable {
    let path: String
    let name: String
    var isCustom: Bool = false
    var id: String { path }
}

enum SystemSoundCatalog {
    private static let supportedExtensions: Set<String> = ["aif", "aiff", "caf", "wav"]

    static func availableSounds(including selectedPaths: [String] = []) -> [SystemSoundChoice] {
        let manager = FileManager.default
        let userSounds = manager.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Sounds", isDirectory: true)
        let directories = [
            URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
            URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
            userSounds
        ].compactMap { $0 }

        var systemPaths = Set<String>()
        for directory in directories {
            guard let urls = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where supportedExtensions.contains(url.pathExtension.lowercased()) {
                // These are private copies prepared for UserNotifications, not
                // additional choices the user intentionally installed.
                guard !url.lastPathComponent.hasPrefix("Codevisor-") else { continue }
                systemPaths.insert(url.standardizedFileURL.path)
            }
        }

        // Sounds the user imported through Settings; they appear in every
        // sound menu alongside the built-in macOS sounds.
        let customDirectory = CustomSoundStore.defaultDirectory().standardizedFileURL
        var customPaths = Set(CustomSoundStore(directory: customDirectory).availableSounds().map(\.path))

        for path in selectedPaths where manager.fileExists(atPath: path) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized.hasPrefix(customDirectory.path + "/") {
                customPaths.insert(path)
            } else {
                systemPaths.insert(path)
            }
        }

        func choices(for paths: Set<String>, isCustom: Bool) -> [SystemSoundChoice] {
            paths.map { path in
                SystemSoundChoice(
                    path: path,
                    name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    isCustom: isCustom
                )
            }
        }
        return (choices(for: systemPaths, isCustom: false) + choices(for: customPaths, isCustom: true))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Owns the device-local presentation policy for chat attention events.
/// Events carry stable ids and server/session routing metadata so the same
/// shape can later arrive from a server-side primary-device coordinator.
@MainActor
final class ChatNotificationManager: NSObject, ChatNotificationDelivering, UNUserNotificationCenterDelegate {
    static let shared = ChatNotificationManager()

    private static let categoryIdentifier = "CODEVISOR_CHAT_ATTENTION"
    private static let testKey = "isTest"
    private static let sessionIdKey = "sessionId"
    private static let serverIdKey = "serverId"
    private static let kindKey = "kind"
    private static let eventIdKey = "eventId"

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Codevisor",
        category: "ChatNotifications"
    )
    private weak var settingsModel: AppSettingsModel?
    private var previewSound: NSSound?

    private override init() {
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
              settings.systemNotificationsEnabled else { return }
        let current = await center.notificationSettings()
        guard current.authorizationStatus == .notDetermined else { return }
        _ = await requestAuthorization()
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func deliver(_ event: ChatAttentionEvent, sessionIsOpen: Bool) {
        guard let settings = settingsModel?.settings, settings.notificationsEnabled else { return }
        clearNotifications(for: event.sessionId)

        if NSApp.isActive {
            // The visible chat is already the best presentation surface.
            guard !sessionIsOpen, settings.notificationSoundsEnabled else { return }
            playSound(at: soundPath(for: event.kind, settings: settings))
            return
        }

        if settings.systemNotificationsEnabled {
            Task { await schedule(event, settings: settings) }
        } else if settings.notificationSoundsEnabled {
            playSound(at: soundPath(for: event.kind, settings: settings))
        }
    }

    func clearNotifications(for sessionId: UUID) {
        let identifiers = ChatAttentionKind.allCases.map {
            notificationIdentifier(sessionId: sessionId, kind: $0)
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func playPreview(kind: ChatAttentionKind) {
        guard let settings = settingsModel?.settings else { return }
        playSound(at: soundPath(for: kind, settings: settings))
    }

    /// Plays an arbitrary sound file once — Settings uses this to audition
    /// sounds that aren't (yet) assigned to a notification kind.
    func playSample(at path: String) {
        playSound(at: path)
    }

    @discardableResult
    func sendTestNotification(kind: ChatAttentionKind) async -> Bool {
        let status = await authorizationStatus()
        let authorized: Bool
        if status == .notDetermined {
            authorized = await requestAuthorization()
        } else {
            authorized = Self.isAuthorized(status)
        }
        guard authorized, let settings = settingsModel?.settings else { return false }

        let event = ChatAttentionEvent(
            sessionId: UUID(),
            serverId: "test",
            sessionTitle: "Notification Test",
            kind: kind
        )
        await schedule(event, settings: settings, isTest: true)
        return true
    }

    func openSystemNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func schedule(_ event: ChatAttentionEvent, settings: AppSettings, isTest: Bool = false) async {
        let status = await authorizationStatus()
        guard Self.isAuthorized(status) else {
            // The app-level sound preference remains useful even if banners
            // were denied in System Settings.
            if settings.notificationSoundsEnabled {
                playSound(at: soundPath(for: event.kind, settings: settings))
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.kind.notificationTitle
        content.body = event.sessionTitle.isEmpty ? "Chat" : event.sessionTitle
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "chat.\(event.sessionId.uuidString)"
        content.targetContentIdentifier = event.sessionId.uuidString
        content.interruptionLevel = .active
        content.userInfo = [
            Self.eventIdKey: event.id.uuidString,
            Self.sessionIdKey: event.sessionId.uuidString,
            Self.serverIdKey: event.serverId,
            Self.kindKey: event.kind.rawValue,
            Self.testKey: isTest
        ]
        if settings.notificationSoundsEnabled {
            let path = soundPath(for: event.kind, settings: settings)
            content.sound = preparedNotificationSound(at: path) ?? .default
        }

        let identifier = isTest
            ? "codevisor.chat.test.\(event.id.uuidString)"
            : notificationIdentifier(sessionId: event.sessionId, kind: event.kind)
        if !isTest {
            // Keep one current attention item per chat. A later completion
            // supersedes an old question alert (and vice versa).
            clearNotifications(for: event.sessionId)
        }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
            log.error("Scheduling chat notification failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func soundPath(for kind: ChatAttentionKind, settings: AppSettings) -> String {
        switch kind {
        case .finished:
            settings.chatFinishedSoundPath
        case .actionRequired:
            settings.actionRequiredSoundPath
        }
    }

    private func playSound(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            NSSound.beep()
            return
        }
        previewSound?.stop()
        previewSound = sound
        sound.play()
    }

    /// UserNotifications only resolves named sounds from the app bundle or a
    /// Library/Sounds directory. Copy the user's selected macOS sound there so
    /// the system—not the app—plays it and can honor Focus and sound settings.
    private func preparedNotificationSound(at path: String) -> UNNotificationSound? {
        let source = URL(fileURLWithPath: path)
        let supported = ["aif", "aiff", "caf", "wav"].contains(source.pathExtension.lowercased())
        guard supported, FileManager.default.fileExists(atPath: source.path) else { return nil }
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let sounds = library.appendingPathComponent("Sounds", isDirectory: true)
        let destination = sounds.appendingPathComponent(
            CustomSoundStore.preparedNotificationSoundName(for: source)
        )
        do {
            try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: destination.lastPathComponent))
        } catch {
            log.error("Preparing notification sound failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func notificationIdentifier(sessionId: UUID, kind: ChatAttentionKind) -> String {
        "codevisor.chat.\(sessionId.uuidString).\(kind.rawValue)"
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if info[Self.testKey] as? Bool == true {
            return [.banner, .list, .sound]
        }
        // A normal chat request may race with the user returning to Codevisor.
        // Suppress it rather than showing a stale foreground banner.
        if info[Self.sessionIdKey] != nil, NSApp.isActive {
            return []
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard info[Self.testKey] as? Bool != true,
              let sessionId = info[Self.sessionIdKey] as? String,
              UUID(uuidString: sessionId) != nil,
              let serverId = info[Self.serverIdKey] as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .codevisorOpenChatNotification,
            object: nil,
            userInfo: [Self.sessionIdKey: sessionId, Self.serverIdKey: serverId]
        )
    }
}

extension ChatAttentionKind: CaseIterable {}
