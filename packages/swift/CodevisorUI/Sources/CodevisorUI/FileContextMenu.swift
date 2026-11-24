import SwiftUI

extension View {
  public func fileContextMenu(_ file: ViewableFile?) -> some View {
    modifier(FileContextMenu(file: file))
  }
}

private struct FileContextMenu: ViewModifier {
  @Environment(\.fileOpener) private var opener
  let file: ViewableFile?

  func body(content: Content) -> some View {
    content.contextMenu {
      if let opener, let file, !file.isPendingCapture {
        FileMenuContent(opener.menu(for: file))
      }
    }
  }
}
