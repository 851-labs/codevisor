import CodevisorClient
import Foundation

public enum WorkspacePlace: Equatable, Sendable {
  case machine(CodevisorMachine)
  case sandbox(name: String)

  public static let sandboxSystemImage = "shippingbox"
}
