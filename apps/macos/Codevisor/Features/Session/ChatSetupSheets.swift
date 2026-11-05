import CodevisorCore
import SwiftUI

struct ChatSetupSheets: ViewModifier {
  @Bindable var controller: SessionController
  @Environment(WorkspaceActivity.self) private var activity: WorkspaceActivity?

  func body(content: Content) -> some View {
    content
      .sheet(item: isActive ? $controller.presentedSetupRequest : .constant(nil)) { request in
        SetupRequestSheet(request: request, controller: controller)
      }
      .modifier(ProjectCloneSheetPresenter(controller: controller, isEnabled: isActive))
  }

  private var isActive: Bool { activity?.isActive ?? true }
}
