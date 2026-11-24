import StreamMarkdown
import SwiftUI

@MainActor
public struct FileMenuAction: Identifiable {
  public let title: String
  public let systemImage: String
  public let perform: @MainActor () -> Void

  nonisolated public var id: String { title }

  public init(_ title: String, systemImage: String, perform: @escaping @MainActor () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.perform = perform
  }

  var markdownItem: MarkdownLinkMenuItem {
    .action(title: title, systemImage: systemImage, perform: perform)
  }
}

public struct FileMenuEntries: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let preview = FileMenuEntries(rawValue: 1 << 0)
  public static let openInTab = FileMenuEntries(rawValue: 1 << 1)
  public static let download = FileMenuEntries(rawValue: 1 << 2)
}

@MainActor
public struct FileMenu {
  public var title: String
  public var sections: [[FileMenuAction]]
  public var share: FileTransferItem?

  public init(title: String, sections: [[FileMenuAction]], share: FileTransferItem? = nil) {
    self.title = title
    self.sections = sections.filter { !$0.isEmpty }
    self.share = share
  }

  public func markdownItems(share present: (@MainActor (FileTransferItem) -> Void)?) -> [MarkdownLinkMenuItem] {
    var groups = sections.map { $0.map(\.markdownItem) }
    if let share, let present, !groups.isEmpty {
      groups[groups.count - 1].append(
        .action(title: "Share…", systemImage: "square.and.arrow.up") { present(share) })
    }
    return Array(groups.joined(separator: [.separator]))
  }
}

public struct FileMenuContent: View {
  private let menu: FileMenu

  public init(_ menu: FileMenu) {
    self.menu = menu
  }

  public var body: some View {
    ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
      if index > 0 { Divider() }
      ForEach(section) { action in
        Button(action.title, systemImage: action.systemImage, action: action.perform)
          .labelStyle(.titleAndIcon)
      }
      if index == menu.sections.count - 1, let share = menu.share {
        FileShareLink(item: share)
      }
    }
  }
}
