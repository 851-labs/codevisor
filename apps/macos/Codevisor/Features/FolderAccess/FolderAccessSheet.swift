import CodevisorClient
import CodevisorCore
import SwiftUI

struct FolderAccessSheet: View {
  let folder: ServerFirstRunFolder
  let folders: FirstRunFolderAccess

  var body: some View {
    VStack(spacing: 20) {
      FolderAccessHeader(folder: folder)
      VStack(spacing: 12) {
        HStack {
          Button("Not Now") { answer(allow: false) }
            .keyboardShortcut(.cancelAction)
          Spacer()
          FolderAccessStepDots(folders: folders)
          Spacer()
          Button("Allow") { answer(allow: true) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .disabled(isAnswering)
        if isAnswering { FolderAccessWaiting() }
      }
    }
    .padding(24)
    .frame(width: 420)
    .animation(.snappy(duration: 0.2), value: isAnswering)
    .interactiveDismissDisabled()
  }

  private var isAnswering: Bool {
    folders.answeringId == folder.id
  }

  private func answer(allow: Bool) {
    Task { await folders.answer(folder, allow: allow) }
  }
}
