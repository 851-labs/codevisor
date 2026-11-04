import CodevisorCore
import Foundation

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

@MainActor
public final class BrowserSignIn {
  public static let shared = BrowserSignIn()

  public static let returnHost = "signed-in"
  public static let returnGrace: Duration = .seconds(2)

  public typealias WindowRestore = @MainActor () -> Void

  private struct Waiting {
    let id: UUID
    let continuation: CheckedContinuation<URL?, Never>
    var leftApp = false
    var returning: Task<Void, Never>?
  }

  private static let callbackHosts: Set<String> = ["cloud-auth", returnHost]

  private let open: @MainActor (URL) -> Bool
  private let rememberWindow: @MainActor () -> WindowRestore?
  private let clock: any Clock<Duration>
  private var waiting: Waiting?
  private var origin: WindowRestore?
  private var observers: [any NSObjectProtocol] = []

  init(
    open: @escaping @MainActor (URL) -> Bool = DefaultBrowser.open,
    rememberWindow: @escaping @MainActor () -> WindowRestore? = BrowserSignIn.rememberFrontWindow,
    clock: any Clock<Duration> = ContinuousClock(),
    notifications: NotificationCenter = .default
  ) {
    self.open = open
    self.rememberWindow = rememberWindow
    self.clock = clock
    observe(notifications)
  }

  public func run(_ url: URL, id: UUID = UUID()) async -> URL? {
    finish(with: nil)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        origin = rememberWindow()
        waiting = Waiting(id: id, continuation: continuation)
        if !open(url) { finish(id, with: nil) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(id) }
    }
  }

  public func cancel(_ id: UUID) {
    finish(id, with: nil)
  }

  public func receive(_ url: URL) -> Bool {
    guard Self.isCallback(url) else { return false }

    restoreOrigin()
    guard let waiting else { return Self.isReturnLink(url) }

    finish(waiting.id, with: url)
    return true
  }

  func appDidResignActive() {
    waiting?.leftApp = true
  }

  func appDidBecomeActive() {
    guard let current = waiting, current.leftApp, current.returning == nil else { return }

    waiting?.returning = Task { [clock] in
      guard (try? await clock.sleep(for: Self.returnGrace)) != nil else { return }
      finish(current.id, with: nil)
    }
  }

  private static func isCallback(_ url: URL) -> Bool {
    guard CodevisorDeeplinkScheme.matches(url.scheme), let host = url.host()?.lowercased() else { return false }
    return callbackHosts.contains(host)
  }

  private static func isReturnLink(_ url: URL) -> Bool {
    url.host()?.lowercased() == returnHost
  }

  private func restoreOrigin() {
    guard let restore = origin else { return }

    origin = nil
    Task { restore() }
  }

  private func finish(_ id: UUID, with callback: URL?) {
    guard waiting?.id == id else { return }
    finish(with: callback)
  }

  private func finish(with callback: URL?) {
    guard let ended = waiting else { return }

    waiting = nil
    ended.returning?.cancel()
    ended.continuation.resume(returning: callback)
  }

  private func observe(_ notifications: NotificationCenter) {
    observers = [
      notifications.addObserver(forName: Self.resignActive, object: nil, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.appDidResignActive() }
      },
      notifications.addObserver(forName: Self.becomeActive, object: nil, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.appDidBecomeActive() }
      },
    ]
  }

  static func rememberFrontWindow() -> WindowRestore? {
    #if os(iOS)
      nil
    #else
      guard let window = NSApp?.keyWindow ?? NSApp?.orderedWindows.first(where: isReturnTarget) else { return nil }
      return { [weak window] in window?.makeKeyAndOrderFront(nil) }
    #endif
  }

  #if os(macOS)
    private static func isReturnTarget(_ window: NSWindow) -> Bool {
      window.isVisible && window.canBecomeMain
    }
  #endif

  #if os(iOS)
    static let resignActive = UIApplication.willResignActiveNotification
    static let becomeActive = UIApplication.didBecomeActiveNotification
  #else
    static let resignActive = NSApplication.didResignActiveNotification
    static let becomeActive = NSApplication.didBecomeActiveNotification
  #endif
}
