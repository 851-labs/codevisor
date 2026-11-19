import CodevisorCore
import SwiftUI

public enum SandboxSettingsSheet: Identifiable, Equatable {
  case newProvider
  case editProvider(ServerSandboxProvider)
  case newProfile(ServerSandboxProvider)

  public var id: String {
    switch self {
    case .newProvider: "new provider"
    case let .editProvider(provider): "edit provider \(provider.id)"
    case let .newProfile(provider): "new profile \(provider.id)"
    }
  }
}
