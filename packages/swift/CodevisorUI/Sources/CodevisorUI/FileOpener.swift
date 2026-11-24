import CodevisorCore
import SwiftUI
import TranscriptKit

#if canImport(AppKit)
  import AppKit
#endif

@MainActor
public struct FileOpener {
  public struct Site: Sendable {
    public let rootPath: String
    public let machineId: String
    public let client: any CodevisorServerClienting

    public init(rootPath: String, machineId: String, client: any CodevisorServerClienting) {
      self.rootPath = rootPath
      self.machineId = machineId
      self.client = client
    }
  }

  public let site: Site
  public let lightbox: FileLightbox
  private let identity: HandlerIdentity
  public let openInTab: (@MainActor (String) -> Bool)?
  public var transfers = FileTransfers()
  public var presentMenu: (@MainActor (FileMenu) -> Void)?
  public var siblings: @MainActor (ViewableFile) -> [ViewableFile] = { [$0] }
  public var poster: @MainActor (ViewableFile) -> OSImage? = { _ in nil }
  public var addToChat: (@MainActor (PreviewFile) -> Void)?

  public init(
    identity: HandlerIdentity, site: Site, lightbox: FileLightbox, openInTab: (@MainActor (String) -> Bool)? = nil
  ) {
    self.identity = identity
    self.site = site
    self.lightbox = lightbox
    self.openInTab = openInTab
  }

  public func scoped(to scope: some Hashable & Sendable) -> FileOpener {
    var opener = FileOpener(
      identity: HandlerIdentity(FileOpenerScope(base: identity, scope: scope)), site: site, lightbox: lightbox,
      openInTab: openInTab)
    opener.transfers = transfers
    opener.presentMenu = presentMenu
    opener.siblings = siblings
    opener.poster = poster
    opener.addToChat = addToChat
    return opener
  }

  public func open(_ file: ViewableFile) {
    guard !file.isPendingCapture else { return }
    if file.isFolder || Self.wantsNewTab, openInNewTab(file) { return }
    guard file.previewKind != .none else { return showMenu(for: file) }

    preview(file)
  }

  public func preview(_ file: ViewableFile) {
    let group = siblings(file).filter { $0.previewKind != .none && !$0.isPendingCapture }
    lightbox.present(file, among: group.contains(file) ? group : [file], opener: self)
  }

  @discardableResult
  public func openInNewTab(_ file: ViewableFile) -> Bool {
    guard let openInTab, file.machineFile != nil, openInTab(file.target) else { return false }

    lightbox.dismiss()
    return true
  }

  public func canOpenInTab(_ file: ViewableFile) -> Bool {
    openInTab != nil && file.machineFile != nil
  }

  public func path(of file: ViewableFile) -> String? {
    if case .onDevice = file { return file.target }
    return FileDocumentLocation.resolve(file.target, relativeTo: site.rootPath)
  }

  public func transferItem(for file: ViewableFile) -> FileTransferItem {
    let path = path(of: file)
    let client = site.client
    return FileTransferItem(name: file.name, mimeType: file.mimeType) {
      guard let path else { throw CodevisorServerClientError.invalidResponse }
      return try await FileDocumentLocation.data(path: path, client: client)
    }
  }

  public func copy(_ file: ViewableFile) {
    let item = transferItem(for: file)
    let report = transfers.reportFailure
    Task {
      if await AttachmentClipboard.copy(item) { return }
      report?("Unable to Copy", "\(item.name) could not be copied. Please try again.")
    }
  }

  public func menu(for file: ViewableFile, omitting omitted: FileMenuEntries = []) -> FileMenu {
    let item = transferItem(for: file)
    return FileMenu(
      title: file.name,
      sections: [
        addToChatActions(for: file), openActions(for: file, omitting: omitted),
        transferActions(for: item, omitting: omitted) + copyActions(for: file),
      ],
      share: item)
  }

  private func showMenu(for file: ViewableFile) {
    presentMenu?(menu(for: file))
  }

  private func addToChatActions(for file: ViewableFile) -> [FileMenuAction] {
    guard let addToChat, let image = file.machineFile, file.previewKind == .image else { return [] }
    return [
      FileMenuAction("Add to Chat", systemImage: "text.bubble") {
        addToChat(image)
        lightbox.dismiss()
      }
    ]
  }

  private func openActions(for file: ViewableFile, omitting omitted: FileMenuEntries) -> [FileMenuAction] {
    var actions: [FileMenuAction] = []
    if !omitted.contains(.preview), file.previewKind != .none {
      actions.append(FileMenuAction("Preview", systemImage: "eye") { preview(file) })
    }
    if !omitted.contains(.openInTab), canOpenInTab(file) {
      actions.append(
        FileMenuAction("Open in New Tab", systemImage: "plus.rectangle.on.rectangle") { openInNewTab(file) })
    }
    return actions
  }

  private func transferActions(for item: FileTransferItem, omitting omitted: FileMenuEntries) -> [FileMenuAction] {
    var actions: [FileMenuAction] = []
    if !omitted.contains(.download), let download = transfers.download {
      actions.append(FileMenuAction("Download", systemImage: FileTransfers.downloadSymbol) { download(item) })
    }
    if let saveAs = transfers.saveAs {
      actions.append(FileMenuAction(FileTransfers.saveAsTitle, systemImage: "square.and.arrow.down") { saveAs(item) })
    }
    return actions
  }

  private func copyActions(for file: ViewableFile) -> [FileMenuAction] {
    [FileMenuAction("Copy", systemImage: "doc.on.doc") { copy(file) }]
  }

  private static var wantsNewTab: Bool {
    #if canImport(AppKit)
      NSApp?.currentEvent?.modifierFlags.contains(.command) == true
    #else
      false
    #endif
  }
}

private struct FileOpenerScope<Scope: Hashable & Sendable>: Equatable, Sendable {
  let base: HandlerIdentity
  let scope: Scope
}

extension FileOpener: Equatable {
  nonisolated public static func == (lhs: FileOpener, rhs: FileOpener) -> Bool {
    lhs.identity == rhs.identity && lhs.site.rootPath == rhs.site.rootPath
      && lhs.site.machineId == rhs.site.machineId && (lhs.openInTab == nil) == (rhs.openInTab == nil)
      && lhs.lightbox === rhs.lightbox
  }
}

extension EnvironmentValues {
  @Entry public var fileOpener: FileOpener?
  @Entry public var fileLightbox: FileLightbox?
}
