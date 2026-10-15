import Foundation

public struct MachineIcon: Identifiable, Hashable, Sendable {
  public let systemImage: String
  public let title: String

  public var id: String { systemImage }

  public static let fallback = MachineIcon(systemImage: "desktopcomputer", title: "iMac")

  public static let choices: [MachineIcon] = [
    MachineIcon(systemImage: "laptopcomputer", title: "MacBook"),
    fallback,
    MachineIcon(systemImage: "macmini", title: "Mac mini"),
    MachineIcon(systemImage: "macstudio", title: "Mac Studio"),
    MachineIcon(systemImage: "macpro.gen3", title: "Mac Pro"),
    MachineIcon(systemImage: "pc", title: "PC"),
    MachineIcon(systemImage: "server.rack", title: "Server"),
    MachineIcon(systemImage: "externaldrive.connected.to.line.below", title: "Network Storage"),
    MachineIcon(systemImage: "cpu", title: "Chip"),
    MachineIcon(systemImage: "cloud", title: "Cloud"),
    MachineIcon(systemImage: "globe", title: "Globe"),
    MachineIcon(systemImage: "terminal", title: "Terminal"),
    MachineIcon(systemImage: "house", title: "Home"),
    MachineIcon(systemImage: "building.2", title: "Office"),
    MachineIcon(systemImage: "flask", title: "Lab"),
  ]

  private init(systemImage: String, title: String) {
    self.systemImage = systemImage
    self.title = title
  }

  public init?(known systemImage: String?) {
    let outline = systemImage == "cloud.fill" ? "cloud" : systemImage
    guard let choice = Self.choices.first(where: { $0.systemImage == outline }) else { return nil }
    self = choice
  }

  public init(resolving systemImage: String?) {
    self = MachineIcon(known: systemImage) ?? Self.fallback
  }
}
