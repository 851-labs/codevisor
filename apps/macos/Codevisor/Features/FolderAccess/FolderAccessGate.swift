import CodevisorCore
import SwiftUI

struct FolderAccessGate: ViewModifier {
  let folders: FirstRunFolderAccess?

  func body(content: Content) -> some View {
    content.sheet(isPresented: .constant(folders?.isAsking == true)) {
      if let folders, let folder = folders.current {
        FolderAccessSheet(folder: folder, folders: folders)
      }
    }
  }
}
