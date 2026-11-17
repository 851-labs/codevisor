import CodevisorCore
import CodevisorUI
import SwiftUI

struct ChatSetupSheets: ViewModifier {
  @Bindable var controller: SessionController
  @Environment(WorkspaceActivity.self) private var activity: WorkspaceActivity?

  func body(content: Content) -> some View {
    content
      .sheet(item: presentsSetup ? $controller.presentedSetupRequest : .constant(nil)) { request in
        SetupRequestSheet(request: request, controller: controller)
      }
      .modifier(ProjectCloneSheetPresenter(controller: controller, isEnabled: presentsClone))
  }

  private var presentsSetup: Bool {
    controller.presentedSetupRequest != nil && isActive
  }

  private var presentsClone: Bool {
    controller.projectClone?.setup.isPresented == true && isActive
  }

  private var isActive: Bool { activity?.isActive ?? true }
}
