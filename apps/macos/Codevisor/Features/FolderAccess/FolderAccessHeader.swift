import CodevisorClient
import SwiftUI

struct FolderAccessHeader: View {
  let folder: ServerFirstRunFolder

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: isDrive ? "externaldrive" : "folder")
        .font(.system(size: 30, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Add Projects from \(folder.name)?")
          .font(.title3.weight(.semibold))
        Text(question)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var question: String {
    FolderAccessProjectList.question(projects: folder.projects, folderPath: folder.path)
  }

  private var isDrive: Bool {
    folder.id.hasPrefix("volume:")
  }
}
