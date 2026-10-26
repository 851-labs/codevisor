import Foundation
#if os(iOS)
  import UIKit
#endif

@MainActor
public protocol RetainedBrowserPage: AnyObject {
  var hasLiveBrowserPage: Bool { get }
  var protectsBrowserPage: Bool { get }
  func discardBrowserPage() async -> Bool
}

public enum BrowserMemoryPressure: Sendable {
  case warning
  case critical
}

@MainActor
public final class BrowserPageRetention {
  public static let shared = BrowserPageRetention()
  private struct Entry {
    weak var page: (any RetainedBrowserPage)?
    var lastUse: Int
  }
  private var entries: [ObjectIdentifier: Entry] = [:]
  private var uses = 0
  private var relieving = false
  #if os(iOS)
    private var memoryObserver: (any NSObjectProtocol)?
  #else
    private var pressure: (any DispatchSourceMemoryPressure)?
  #endif

  public init(observesMemoryPressure: Bool = true) {
    guard observesMemoryPressure else { return }
    #if os(iOS)
      memoryObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in await self?.relieve(.critical) }
      }
    #else
      let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
      source.setEventHandler { [weak self, weak source] in
        let level: BrowserMemoryPressure = source?.data.contains(.critical) == true ? .critical : .warning
        Task { @MainActor [weak self] in await self?.relieve(level) }
      }
      source.resume()
      pressure = source
    #endif
  }

  public func touch(_ page: any RetainedBrowserPage) {
    uses += 1
    entries[ObjectIdentifier(page)] = Entry(page: page, lastUse: uses)
  }

  public func remove(_ page: any RetainedBrowserPage) { entries[ObjectIdentifier(page)] = nil }

  public func relieve(_ pressure: BrowserMemoryPressure) async {
    guard !relieving else { return }
    relieving = true
    defer { relieving = false }
    entries = entries.filter { $0.value.page != nil }
    for (id, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
      guard let page = entry.page, isDiscardable(page), entries[id]?.lastUse == entry.lastUse else { continue }
      if await page.discardBrowserPage(), pressure == .warning { return }
    }
  }

  private func isDiscardable(_ page: any RetainedBrowserPage) -> Bool {
    page.hasLiveBrowserPage && !page.protectsBrowserPage
  }
}

public enum BrowserPageActivity {
  public static let playsMediaScript = """
    [...document.querySelectorAll('audio,video')].some(e => !e.paused && !e.ended)
    """

  public static let canDiscardScript = """
    (() => {
      if (\(playsMediaScript)) return false;
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
