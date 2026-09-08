import Foundation
#if os(iOS)
  import UIKit
#endif

@MainActor
public protocol RetainedBrowserPage: AnyObject {
  var hasLiveBrowserPage: Bool { get }
  var protectsBrowserPage: Bool { get }
  /// Recheck visibility after any asynchronous activity check before discarding.
  func discardBrowserPage() async -> Bool
}

/// A live-page budget, separate from the engine's HTTP cache. Hidden pages keep
/// their DOM, history and scroll position until idle expiry or memory pressure.
@MainActor
public final class BrowserPageRetention {
  public static let shared = BrowserPageRetention()
  private struct Entry {
    weak var page: (any RetainedBrowserPage)?
    var lastUsed: TimeInterval
  }
  private var entries: [ObjectIdentifier: Entry] = [:]
  private let now: () -> TimeInterval
  private let capacity: Int
  private let idleLifetime: TimeInterval
  private var timer: Timer?
  private var pruning = false
  #if os(iOS)
    private var memoryObserver: (any NSObjectProtocol)?
  #else
    private var pressure: (any DispatchSourceMemoryPressure)?
  #endif

  public init(
    capacity: Int = BrowserPageRetention.defaultCapacity, idleLifetime: TimeInterval = 30 * 60,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    automaticallyPrune: Bool = true
  ) {
    self.capacity = capacity
    self.idleLifetime = idleLifetime
    self.now = now
    guard automaticallyPrune else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.prune() }
    }
    #if os(iOS)
      memoryObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in await self?.prune(memoryPressure: true) }
      }
    #else
      let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
      source.setEventHandler { [weak self] in
        Task { @MainActor [weak self] in await self?.prune(memoryPressure: true) }
      }
      source.resume()
      pressure = source
    #endif
  }

  public static var defaultCapacity: Int {
    #if os(iOS)
      6
    #else
      12
    #endif
  }

  public func touch(_ page: any RetainedBrowserPage) {
    entries[ObjectIdentifier(page)] = Entry(page: page, lastUsed: now())
  }

  public func remove(_ page: any RetainedBrowserPage) { entries[ObjectIdentifier(page)] = nil }

  public func prune(memoryPressure: Bool = false) async {
    guard !pruning else { return }
    pruning = true
    defer { pruning = false }
    entries = entries.filter { $0.value.page != nil }
    let candidates = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
    var liveCount = candidates.filter { $0.value.page?.hasLiveBrowserPage == true }.count
    for (id, entry) in candidates {
      guard let page = entry.page, page.hasLiveBrowserPage, !page.protectsBrowserPage,
        entries[id]?.lastUsed == entry.lastUsed,
        memoryPressure || liveCount > capacity || now() - entry.lastUsed >= idleLifetime
      else { continue }
      if await page.discardBrowserPage() { liveCount -= 1 }
    }
  }
}

/// Conservatively retain media and unfinished forms. Failure to inspect a page
/// also retains it; WebKit/Chromium still have their own process memory policies.
public enum BrowserPageActivity {
  public static let canDiscardScript = """
    (() => {
      if ([...document.querySelectorAll('audio,video')].some(e => !e.paused && !e.ended)) return false;
      if ([...document.querySelectorAll('input,textarea,select,[contenteditable="true"]')].some(e => {
        if (e.isContentEditable) return e.textContent.trim().length > 0;
        if (e.tagName === 'SELECT') return [...e.options].some(o => o.selected !== o.defaultSelected);
        if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
        return e.value !== e.defaultValue;
      })) return false;
      return true;
    })()
    """
}
