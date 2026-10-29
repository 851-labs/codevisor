import CodevisorCore
import SwiftUI

public struct MachineIconView: View {
  @Environment(AppEnvironment.self) private var environment
  private let machineId: String

  public init(machineId: String) {
    self.machineId = machineId
  }

  public var body: some View {
    SidebarGroupIcon.machine(machineId, in: environment.machines).image
      .symbolRenderingMode(.monochrome)
      .frame(width: 20)
      .accessibilityHidden(true)
  }
}
