#if canImport(AppKit)
  import AppKit
  import CodevisorCore
  import SwiftUI

  struct MacFileOutline: NSViewRepresentable {
    @Bindable var model: FileExplorerModel
    @Binding var selection: String?
    let searchEntries: [ServerFileEntry]?
    let open: (String) -> Void
    let openInTab: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.drawsBackground = true
      scroll.backgroundColor = .controlBackgroundColor
      scroll.automaticallyAdjustsContentInsets = false
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      let outline = FileOutlineView()
      outline.headerView = nil
      outline.style = .inset
      outline.backgroundColor = .controlBackgroundColor
      outline.rowHeight = 26
      outline.intercellSpacing = NSSize(width: 0, height: 0)
      outline.indentationPerLevel = 16
      outline.allowsEmptySelection = true
      outline.allowsMultipleSelection = false
      outline.focusRingType = .none
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
      outline.addTableColumn(column)
      outline.outlineTableColumn = column
      outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
      outline.delegate = context.coordinator
      outline.dataSource = context.coordinator
      outline.target = context.coordinator
      outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
      outline.openSelection = { [weak outline, weak coordinator = context.coordinator] in
        guard let outline else { return }
        coordinator?.activate(outline.selectedRow)
      }
      outline.setAccessibilityLabel("Files")
      let menu = NSMenu()
      let item = NSMenuItem(title: "Open in New Tab", action: #selector(Coordinator.openInTab(_:)), keyEquivalent: "")
      item.target = context.coordinator
      menu.addItem(item)
      outline.menu = menu
      context.coordinator.outline = outline
      scroll.documentView = outline
      return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
      context.coordinator.parent = self
      context.coordinator.reload()
    }

    final class Node: NSObject {
      let entry: ServerFileEntry
      init(_ entry: ServerFileEntry) { self.entry = entry }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
      var parent: MacFileOutline
      weak var outline: NSOutlineView?
      var nodes: [String: Node] = [:]
      var syncing = false
      var listings: [String: [ServerFileEntry]] = [:]
      var expanded: Set<String> = []
      var searchEntries: [ServerFileEntry]?
      init(_ parent: MacFileOutline) { self.parent = parent }

      func reload() {
        guard let outline,
          listings != parent.model.listings || expanded != parent.model.expanded
            || searchEntries != parent.searchEntries
        else { return }
        let selection = parent.selection
        listings = parent.model.listings
        expanded = parent.model.expanded
        searchEntries = parent.searchEntries
        for entries in Array(listings.values) + [searchEntries ?? []] {
          for entry in entries where nodes[entry.path]?.entry != entry { nodes[entry.path] = Node(entry) }
        }
        syncing = true
        outline.reloadData()
        for path in searchEntries == nil ? expanded.sorted() : [] {
          if let node = nodes[path] { outline.expandItem(node) }
        }
        if let selection, let node = nodes[selection] {
          let row = outline.row(forItem: node)
          if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        syncing = false
      }

      private func children(_ item: Any?) -> [ServerFileEntry] {
        if let searchEntries { return item == nil ? searchEntries : [] }
        return parent.model.listings[(item as? Node)?.entry.path ?? parent.model.root] ?? []
      }
      func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
      func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let entry = children(item)[index]
        if let node = nodes[entry.path] { return node }
        let node = Node(entry)
        nodes[entry.path] = node
        return node
      }
      func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        searchEntries == nil && (item as? Node)?.entry.isDirectory == true
      }
      func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard !syncing, let node = item as? Node else { return true }
        parent.model.setExpanded(node.entry.path, to: true)
        Task { await parent.model.load(node.entry.path) }
        return true
      }
      func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if !syncing, let node = item as? Node { parent.model.setExpanded(node.entry.path, to: false) }
        return true
      }
      func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("fileCell")
        let cell =
          (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier)
        cell.textField?.stringValue =
          searchEntries == nil ? node.entry.name : parent.model.relativePath(node.entry.path)
        cell.textField?.lineBreakMode = searchEntries == nil ? .byTruncatingMiddle : .byTruncatingHead
        cell.imageView?.image =
          node.entry.isDirectory
          ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
          : FileIcon.nativeImage(for: node.entry.path)
        cell.imageView?.contentTintColor = node.entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
        cell.toolTip = node.entry.path
        return cell
      }
      private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
          icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
          icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
          label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
          label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
          label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = icon
        cell.textField = label
        return cell
      }
      func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let outline else { return }
        parent.selection = (outline.item(atRow: outline.selectedRow) as? Node)?.entry.path
      }
      @objc func doubleClicked(_ sender: NSOutlineView) { activate(sender.clickedRow) }
      func activate(_ row: Int) {
        guard let node = outline?.item(atRow: row) as? Node else { return }
        if node.entry.isDirectory {
          Task { await parent.model.toggle(node.entry.path) }
        } else {
          parent.open(node.entry.path)
        }
      }
      @objc func openInTab(_ sender: NSMenuItem) {
        guard let outline, let node = outline.item(atRow: outline.clickedRow) as? Node, !node.entry.isDirectory else {
          return
        }
        parent.openInTab(node.entry.path)
      }
      func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let outline, let node = outline.item(atRow: outline.clickedRow) as? Node else { return false }
        return !node.entry.isDirectory
      }
    }
  }

  private final class FileOutlineView: NSOutlineView {
    var openSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
      if event.keyCode == 36 || event.keyCode == 76 { openSelection?() } else { super.keyDown(with: event) }
    }
  }
#endif
