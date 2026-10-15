import CodevisorCore

public enum EntitySystemSymbol {
  public static let project = "folder.fill"
  public static let projectList = "folder"
  public static let workspace = "square.grid.2x2.fill"

  public static func machine(_ machine: CodevisorMachine) -> String {
    MachineIcon.choice(machine.icon)?.systemImage ?? MachineIcon.fallback
  }
}
