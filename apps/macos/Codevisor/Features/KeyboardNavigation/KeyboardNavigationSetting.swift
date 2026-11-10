import AppKit
import Observation

@Observable
final class KeyboardNavigationSetting {
  private static let preferenceKey = "AppleKeyboardUIMode" as CFString
  private static let changeNotification = Notification.Name("com.apple.KeyboardUIModeDidChange")
  private static let enabledFlag = 2

  private(set) var isEnabled = KeyboardNavigationSetting.readIsEnabled()
  @ObservationIgnored private var observer: (any NSObjectProtocol)?

  init() {
    observer = DistributedNotificationCenter.default().addObserver(
      forName: Self.changeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.isEnabled = Self.readIsEnabled() }
    }
  }

  isolated deinit {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
  }

  func turnOn() {
    Self.writeMode(Self.readMode() | Self.enabledFlag)
    DistributedNotificationCenter.default().postNotificationName(
      Self.changeNotification, object: nil, userInfo: nil, deliverImmediately: true
    )
    isEnabled = Self.readIsEnabled()
  }

  private static func readIsEnabled() -> Bool {
    readMode() & enabledFlag != 0
  }

  private static func readMode() -> Int {
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let value = CFPreferencesCopyValue(
      preferenceKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
    )
    return (value as? NSNumber)?.intValue ?? 0
  }

  private static func writeMode(_ mode: Int) {
    CFPreferencesSetValue(
      preferenceKey, mode as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    )
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
  }
}
