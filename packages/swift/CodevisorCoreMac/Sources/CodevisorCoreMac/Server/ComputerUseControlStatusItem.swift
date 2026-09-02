import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

/// ChatGPT's app-icons-plus-pointer control is a custom status item owned by
/// its Computer Use helper, not a ScreenCaptureKit-provided view. Keep our
/// native sharing stream for the purple system treatment and present the same
/// compact, actionable status affordance here.
@MainActor
private final class ComputerUseStatusView: NSView {
  var icons: [NSImage] = [] {
    didSet { needsDisplay = true }
  }
  var isActive = false {
    didSet { needsDisplay = true }
  }
  /// Matches the single active agent's cursor color; neutral when several
  /// agents share the chip.
  var cursorColor = NSColor(calibratedWhite: 0.94, alpha: 1) {
    didSet { needsDisplay = true }
  }
  var onActivate: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    onActivate?()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let chipHeight = min(ComputerUseStatusMetrics.chipHeight, bounds.height)
    let chipRect = CGRect(
      x: bounds.minX,
      y: bounds.midY - chipHeight / 2,
      width: bounds.width,
      height: chipHeight
    )
    let capsule = NSBezierPath(
      roundedRect: chipRect,
      xRadius: chipHeight / 2,
      yRadius: chipHeight / 2
    )
    NSColor.labelColor.withAlphaComponent(isActive ? 0.24 : 0.16).setFill()
    capsule.fill()

    for (index, icon) in icons.enumerated() {
      icon.draw(
        in: ComputerUseStatusMetrics.iconFrame(index: index, in: bounds),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
    }

    let cursorPath = computerUsePointerPath(
      in: ComputerUseStatusMetrics.cursorFrame(appCount: icons.count, in: bounds),
      rotation: ComputerUseStatusMetrics.cursorArtworkRotation
    )
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 0.8
    shadow.shadowOffset = CGSize(width: 0, height: -0.3)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.set()
    cursorColor.setFill()
    cursorPath.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}

@MainActor
final class ComputerUseControlStatusItem: NSObject {
  static let shared = ComputerUseControlStatusItem()

  private struct Entry {
    let appName: String
    let icon: NSImage
    let agentLabel: String?
    let colorIndex: Int
  }

  private var entries: [ComputerUseShareKey: Entry] = [:]
  private var statusItem: NSStatusItem?
  private var statusView: ComputerUseStatusView?

  func activate(key: ComputerUseShareKey, appName: String, agentLabel: String?, colorIndex: Int) {
    entries[key] = Entry(
      appName: appName,
      icon: applicationIcon(pid: key.pid),
      agentLabel: agentLabel,
      colorIndex: colorIndex
    )
    refresh()
  }

  func remove(key: ComputerUseShareKey) {
    entries.removeValue(forKey: key)
    refresh()
  }

  func remove(pid: pid_t) {
    entries = entries.filter { $0.key.pid != pid }
    refresh()
  }

  func remove(sessionID: String) {
    entries = entries.filter { $0.key.sessionID != sessionID }
    refresh()
  }

  func removeAll() {
    entries.removeAll()
    refresh()
  }

  /// Backstop against stale rows: a pid with no live process can never be
  /// controlled again, so its entries must not survive in the menu bar.
  private func pruneTerminatedApps() {
    let deadPIDs = Set(entries.keys.map(\.pid)).filter { pid in
      guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
      return app.isTerminated
    }
    guard !deadPIDs.isEmpty else { return }
    entries = entries.filter { !deadPIDs.contains($0.key.pid) }
  }

  private func refresh() {
    pruneTerminatedApps()
    guard !entries.isEmpty else {
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusView = nil
      }
      return
    }

    let controlledApps = controlledApps()
    let visibleApps = Array(controlledApps.prefix(4)).map(\.1)
    let width = ComputerUseStatusMetrics.width(appCount: visibleApps.count)
    let item: NSStatusItem
    if let statusItem {
      item = statusItem
    } else {
      item = NSStatusBar.system.statusItem(withLength: width)
      let view = ComputerUseStatusView(
        frame: CGRect(
          x: 0,
          y: 0,
          width: width,
          height: NSStatusBar.system.thickness
        )
      )
      view.toolTip = "Computer Use"
      view.onActivate = { [weak self] in
        self?.showMenu()
      }
      item.view = view
      statusItem = item
      statusView = view
    }

    item.length = width
    if let statusView {
      statusView.frame.size = CGSize(width: width, height: NSStatusBar.system.thickness)
      statusView.icons = visibleApps.map(\.icon)
      statusView.cursorColor =
        entries.count == 1
        ? ComputerUseCursorPalette.color(at: entries.values.first?.colorIndex ?? 0)
        : NSColor(calibratedWhite: 0.94, alpha: 1)
    }
  }

  private func showMenu() {
    pruneTerminatedApps()
    refresh()
    guard let statusView else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    // One row per agent/app pairing so stopping one agent's control never
    // tears down another agent that shares the same app.
    for (key, entry) in sortedEntries() {
      let title =
        "Stop Using \(entry.appName)"
        + (entry.agentLabel.map { " — \($0)" } ?? "")
      let menuItem = NSMenuItem(
        title: title,
        action: #selector(stopUsing(_:)),
        keyEquivalent: ""
      )
      let attributedTitle = NSMutableAttributedString(
        string: "● ",
        attributes: [
          .foregroundColor: ComputerUseCursorPalette.color(at: entry.colorIndex)
        ]
      )
      attributedTitle.append(
        NSAttributedString(
          string: title,
          attributes: [.foregroundColor: NSColor.labelColor]
        ))
      menuItem.attributedTitle = attributedTitle
      menuItem.target = self
      menuItem.representedObject = ComputerUseShareKeyBox(key: key)
      menuItem.image = entry.icon
      menuItem.image?.size = CGSize(width: 18, height: 18)
      menu.addItem(menuItem)
    }
    statusView.isActive = true
    statusView.displayIfNeeded()
    defer { statusView.isActive = false }
    menu.popUp(
      positioning: nil,
      at: CGPoint(x: statusView.bounds.minX, y: statusView.bounds.minY),
      in: statusView
    )
  }

  private func controlledApps() -> [(pid_t, Entry)] {
    let entriesByPID = Dictionary(grouping: entries) { $0.key.pid }
    return entriesByPID.compactMap { pid, keyedEntries -> (pid_t, Entry)? in
      keyedEntries.first.map { (pid, $0.value) }
    }.sorted { lhs, rhs in
      lhs.1.appName.localizedCaseInsensitiveCompare(rhs.1.appName) == .orderedAscending
    }
  }

  private func sortedEntries() -> [(ComputerUseShareKey, Entry)] {
    entries.sorted { lhs, rhs in
      let appOrder = lhs.value.appName.localizedCaseInsensitiveCompare(rhs.value.appName)
      if appOrder != .orderedSame { return appOrder == .orderedAscending }
      return (lhs.value.agentLabel ?? "") < (rhs.value.agentLabel ?? "")
    }
  }

  @objc private func stopUsing(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? ComputerUseShareKeyBox else { return }
    ComputerUsePresentationState.shared.stopUsing(key: box.key)
  }

  private func applicationIcon(pid: pid_t) -> NSImage {
    if let app = NSRunningApplication(processIdentifier: pid),
      let bundleURL = app.bundleURL
    {
      let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
      icon.size = CGSize(width: 18, height: 18)
      return icon
    }
    return NSImage(
      systemSymbolName: "app.fill",
      accessibilityDescription: "Controlled app"
    ) ?? NSImage(size: CGSize(width: 18, height: 18))
  }

}

/// NSMenuItem.representedObject round-trips through Objective-C, so the value
/// key is carried in a small reference box rather than a bare Swift struct.
private final class ComputerUseShareKeyBox: NSObject {
  let key: ComputerUseShareKey
  init(key: ComputerUseShareKey) { self.key = key }
}
