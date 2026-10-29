import Foundation

public enum SandboxSettingsPage: Hashable, Sendable {
  case editProfile(profileId: String)
}

public enum SandboxSettingsNavigation: Equatable, Sendable {
  case push(SandboxSettingsPage)
  case reset(to: SandboxSettingsPage?)
  case pop

  public func applied<Route>(
    to path: [Route],
    route: (SandboxSettingsPage) -> Route,
    isSandboxPage: (Route) -> Bool
  ) -> [Route] {
    switch self {
    case let .push(page): path + [route(page)]
    case let .reset(page): path.filter { !isSandboxPage($0) } + (page.map { [route($0)] } ?? [])
    case .pop: Array(path.dropLast())
    }
  }
}
