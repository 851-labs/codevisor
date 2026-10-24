#if DEBUG
  import AppKit
  import CodevisorCore
  import UserNotifications

  enum BentoNotifications {
    static var handshakeDirectory: URL? {
      ProcessInfo.processInfo.environment["CODEVISOR_BENTO_NOTIFICATIONS"].map { URL(fileURLWithPath: $0) }
    }

    private static let postingGap = Duration.milliseconds(700)
    private static let pollInterval = Duration.milliseconds(100)
    private static let notificationIdBase = 900

    @MainActor
    static func run(handshake directory: URL) -> Never {
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      Task {
        let environment = demoEnvironment()
        let manager = ChatNotificationManager.shared
        manager.attach(to: environment)
        var hidden: [NSRunningApplication] = []
        if await manager.requestAuthorization() {
          hidden = hideOtherApps()
          NSApp.hide(nil)
          try? await Task.sleep(for: postingGap)
          if NSApp.isActive {
            report("active", in: directory)
          } else {
            await post(through: manager)
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications().count
            report("posted \(delivered)", in: directory)
          }
        } else {
          report("denied", in: directory)
        }
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path) {
          try? await Task.sleep(for: pollInterval)
        }
        events.forEach { manager.clearNotifications(for: $0.sessionId) }
        hidden.forEach { $0.unhide() }
        withExtendedLifetime(environment) { exit(0) }
      }
      application.run()
      exit(0)
    }

    @MainActor
    private static func demoEnvironment() -> AppEnvironment {
      let environment = DemoEnvironment.make()
      environment.settings.setNotificationsEnabled(true)
      environment.settings.setSystemNotificationsEnabled(true)
      environment.settings.setNotificationSoundsEnabled(false)
      return environment
    }

    @MainActor
    private static func hideOtherApps() -> [NSRunningApplication] {
      let visible = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current
      }
      visible.forEach { $0.hide() }
      return visible
    }

    @MainActor
    private static func post(through manager: ChatNotificationManager) async {
      for event in events {
        manager.deliver(event)
        try? await Task.sleep(for: postingGap)
      }
    }

    private static func report(_ status: String, in directory: URL) {
      try? status.write(to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
    }

    private static let events = DemoWorld.notifications.reversed().enumerated().map { offset, notification in
      ChatAttentionEvent(
        sessionId: DemoModels.id(notificationIdBase + offset), serverId: notification.machine.serverId,
        sessionTitle: notification.chatTitle, kind: notification.needsAction ? .actionRequired : .finished)
    }
  }
#endif
