import Foundation

public struct SidebarMachineGroup: Equatable {
  public let key: String
  public let orderKey: String
  public let heading: SidebarWorkspaceGroup.Heading

  public init(key: String, orderKey: String, heading: SidebarWorkspaceGroup.Heading) {
    self.key = key
    self.orderKey = orderKey
    self.heading = heading
  }
}
