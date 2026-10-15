import Foundation

public struct MachineIcon: Identifiable, Hashable, Sendable {
  public let systemImage: String
  public let title: String

  public var id: String { systemImage }

  public static let choices: [MachineIcon] = [
    MachineIcon(systemImage: "laptopcomputer", title: "MacBook"),
    MachineIcon(systemImage: "desktopcomputer", title: "iMac"),
    MachineIcon(systemImage: "macmini", title: "Mac mini"),
    MachineIcon(systemImage: "macstudio", title: "Mac Studio"),
    MachineIcon(systemImage: "macpro.gen3", title: "Mac Pro"),
    MachineIcon(systemImage: "pc", title: "PC"),
    MachineIcon(systemImage: "server.rack", title: "Server"),
    MachineIcon(systemImage: "externaldrive.connected.to.line.below", title: "Network Storage"),
    MachineIcon(systemImage: "cpu", title: "Chip"),
    MachineIcon(systemImage: "cloud.fill", title: "Cloud"),
    MachineIcon(systemImage: "globe", title: "Globe"),
    MachineIcon(systemImage: "terminal", title: "Terminal"),
    MachineIcon(systemImage: "house", title: "Home"),
    MachineIcon(systemImage: "building.2", title: "Office"),
    MachineIcon(systemImage: "flask", title: "Lab"),
  ]

  public static func choice(_ systemImage: String?) -> MachineIcon? {
    choices.first { $0.systemImage == systemImage }
  }
}
