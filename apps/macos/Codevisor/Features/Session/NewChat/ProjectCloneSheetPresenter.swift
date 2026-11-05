import CodevisorCore
import SwiftUI

struct ProjectCloneSheetPresenter: ViewModifier {
  let controller: SessionController
  var isEnabled = true

  func body(content: Content) -> some View {
    content.sheet(isPresented: isPresented) {
      if let setup = controller.projectClone?.setup {
        ProjectSetupSheet(setup: setup)
      }
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { isEnabled && controller.projectClone?.setup.isPresented == true },
      set: { presented in
        guard !presented, let setup = controller.projectClone?.setup, !setup.isRunning else { return }
        setup.cancel()
      }
    )
  }
}
