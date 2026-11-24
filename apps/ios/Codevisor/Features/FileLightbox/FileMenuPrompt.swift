import CodevisorUI
import Observation
import SwiftUI

@MainActor
@Observable
final class FileMenuPrompt {
  private(set) var menu: FileMenu?

  func present(_ menu: FileMenu) {
    self.menu = menu
  }

  func dismiss() {
    menu = nil
  }
}

extension View {
  func fileMenuPrompt(_ prompt: FileMenuPrompt, share: (@MainActor (FileTransferItem) -> Void)?) -> some View {
    modifier(FileMenuPromptPresenter(prompt: prompt, share: share))
  }
}

private struct FileMenuPromptPresenter: ViewModifier {
  let prompt: FileMenuPrompt
  let share: (@MainActor (FileTransferItem) -> Void)?

  func body(content: Content) -> some View {
    content.confirmationDialog(prompt.menu?.title ?? "", isPresented: isPresented, titleVisibility: .visible) {
      if let menu = prompt.menu {
        ForEach(menu.sections.flatMap { $0 }) { action in
          Button(action.title, action: action.perform)
        }
        if let item = menu.share, let share {
          Button("Share…") { share(item) }
        }
      }
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { prompt.menu != nil },
      set: { presented in
        if !presented { prompt.dismiss() }
      })
  }
}
