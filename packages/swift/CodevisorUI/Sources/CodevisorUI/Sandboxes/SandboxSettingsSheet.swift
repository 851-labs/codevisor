import CodevisorCore
import SwiftUI

public enum SandboxSettingsSheet: Identifiable, Equatable {
  case newProvider(vendorId: String?)
  case editProvider(ServerSandboxProvider)
  case newProfile(ServerSandboxProvider)

  public var id: String {
    switch self {
    case let .newProvider(vendorId): "new provider \(vendorId ?? "")"
    case let .editProvider(provider): "edit provider \(provider.id)"
    case let .newProfile(provider): "new profile \(provider.id)"
    }
  }
}
