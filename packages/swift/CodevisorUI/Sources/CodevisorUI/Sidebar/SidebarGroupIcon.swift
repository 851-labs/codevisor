import SwiftUI

public enum SidebarGroupIcon: Equatable, Sendable {
  case system(String)
  case sandboxVendor(String)

  public var image: Image {
    switch self {
    case let .system(name): Image(systemName: name)
    case let .sandboxVendor(vendor): CodevisorSymbol.sandboxVendor(vendor)
    }
  }
}
