import AppKit
import SwiftUI

struct SidebarToggleHelp: NSViewRepresentable {
  let help: String

  final class Probe: NSView {
    var help = "" {
      didSet { apply() }
    }

    private var addedItemsObserver: NSObjectProtocol?
    private var toolTipObservations: [NSKeyValueObservation] = []

    isolated deinit {
      addedItemsObserver.map(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observeAddedItems()
      observeSidebarToggles()
    }

    private func observeAddedItems() {
      addedItemsObserver.map(NotificationCenter.default.removeObserver)
      addedItemsObserver = NotificationCenter.default.addObserver(
        forName: NSToolbar.willAddItemNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.observeSidebarToggles() }
      }
    }

    private func observeSidebarToggles() {
      toolTipObservations = sidebarToggles.map { item in
        item.observe(\.toolTip) { [weak self] _, _ in
          MainActor.assumeIsolated { self?.apply() }
        }
      }
      apply()
    }

    private func apply() {
      for item in sidebarToggles where item.toolTip != help {
        item.toolTip = help
      }
    }

    private var sidebarToggles: [NSToolbarItem] {
      window?.toolbar?.items.filter(Self.isSidebarToggle) ?? []
    }

    private static func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
      item.itemIdentifier == .toggleSidebar
        || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar")
    }
  }

  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.help = help
    return probe
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.help = help
  }
}
