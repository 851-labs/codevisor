import CodevisorCore
import SwiftUI

struct GitRequirement: ViewModifier {
  let machines: MachineController

  func body(content: Content) -> some View {
    content.sheet(isPresented: .constant(isWaitingForGit)) {
      GitRequiredSheet()
    }
  }

  private var isWaitingForGit: Bool {
    machines.isWaitingForGit(on: CodevisorMachine.local.id)
  }
}
