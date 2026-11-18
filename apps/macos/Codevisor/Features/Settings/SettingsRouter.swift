import AppKit
import CodevisorCore
import CodevisorUI
import Observation

enum SettingsTab: String, CaseIterable, Identifiable {
  case account, machines, projects, sandboxes
  case general, updates, notifications, shortcuts
  case agents, plugins, skills
  case developer

  static let sidebarGroups: [[SettingsTab]] = [
    [.account, .machines, .projects, .sandboxes],
    [.general, .updates, .notifications, .shortcuts],
    [.agents, .plugins, .skills],
    [.developer],
  ]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .account: "Account"
    case .updates: "Updates"
    case .general: "General"
    case .notifications: "Notifications"
    case .shortcuts: "Shortcuts"
    case .agents: "Harnesses"
    case .skills: "Skills"
    case .plugins: "Plugins"
    case .projects: "Projects"
    case .machines: "Machines"
    case .sandboxes: "Sandboxes"
    case .developer: "Developer"
    }
  }

  var icon: SettingsSectionIcon {
    switch self {
    case .account: .account
    case .updates: .updates
    case .general: .general
    case .notifications: .notifications
    case .shortcuts: .shortcuts
    case .agents: .harnesses
    case .skills: .skills
    case .plugins: .plugins
    case .projects: .projects
    case .machines: .machines
    case .sandboxes: .sandboxes
    case .developer: .developer
    }
  }
}

enum SettingsPaneRoute: Hashable {
  case project(ProjectGroup.ID)
  case sandbox(SandboxSettingsPage)
  case pluginCatalog
  case plugin(String)
  case cloudAccount(CloudAccountPage)
}

struct SettingsLocation: Equatable {
  var tab: SettingsTab
  var panePath: [SettingsPaneRoute]

  func closing(_ route: SettingsPaneRoute) -> SettingsLocation {
    SettingsLocation(tab: tab, panePath: Array(panePath.prefix { $0 != route }))
  }
}

struct HarnessAccountSettingsRequest: Equatable {
  let machineId: String
  let harnessId: String
}

@MainActor
@Observable
final class SettingsRouter {
  static let shared = SettingsRouter()
  @ObservationIgnored weak var controlWindow: NSWindow?
  var selectedTab: SettingsTab = .general
  var panePath: [SettingsPaneRoute] = []
  var projectCreationMachineId: String?
  private(set) var backHistory: [SettingsLocation] = []
  private(set) var forwardHistory: [SettingsLocation] = []
  @ObservationIgnored var pendingAppliedLocation: SettingsLocation?
  var pendingHarnessAccountRequest: HarnessAccountSettingsRequest?

  var currentLocation: SettingsLocation {
    SettingsLocation(tab: selectedTab, panePath: panePath)
  }

  var canGoBack: Bool { !backHistory.isEmpty || !panePath.isEmpty }
  var canGoForward: Bool { !forwardHistory.isEmpty }

  func recordNavigation(from previous: SettingsLocation) {
    backHistory.append(previous)
    if backHistory.count > 50 { backHistory.removeFirst() }
    forwardHistory.removeAll()
  }

  func goBack() {
    let parent = panePath.isEmpty ? nil : SettingsLocation(tab: selectedTab, panePath: Array(panePath.dropLast()))
    guard let target = backHistory.popLast() ?? parent else { return }
    forwardHistory.append(currentLocation)
    apply(target)
  }

  func goForward() {
    guard let target = forwardHistory.popLast() else { return }
    backHistory.append(currentLocation)
    apply(target)
  }

  func close(_ route: SettingsPaneRoute) {
    let target = currentLocation.closing(route)
    backHistory = Self.history(backHistory, closing: route, beside: target)
    forwardHistory = Self.history(forwardHistory, closing: route, beside: target)
    apply(target)
  }

  private static func history(
    _ history: [SettingsLocation], closing route: SettingsPaneRoute, beside current: SettingsLocation
  ) -> [SettingsLocation] {
    var closed: [SettingsLocation] = []
    for location in history.map({ $0.closing(route) }) where location != closed.last {
      closed.append(location)
    }
    if closed.last == current { closed.removeLast() }
    return closed
  }

  private func apply(_ location: SettingsLocation) {
    guard location != currentLocation else { return }
    pendingAppliedLocation = location
    selectedTab = location.tab
    panePath = location.panePath
  }

  func showMachines() {
    panePath = []
    selectedTab = .machines
  }

  func showSandboxes() {
    panePath = []
    selectedTab = .sandboxes
  }

  func navigate(_ navigation: SandboxSettingsNavigation) {
    panePath = navigation.applied(to: panePath, route: SettingsPaneRoute.sandbox) { route in
      if case .sandbox = route { return true }
      return false
    }
  }

  func showProjects(machineId: String? = nil) {
    projectCreationMachineId = machineId
    panePath = []
    selectedTab = .projects
  }

  func showProject(_ project: Project) {
    projectCreationMachineId = project.serverId
    panePath = [.project(ProjectGroup.routeID(for: project))]
    selectedTab = .projects
  }

  func showUpdates() {
    panePath = []
    selectedTab = .updates
  }

  func showHarnesses(machineId: String? = nil) {
    pendingHarnessAccountRequest = nil
    panePath = []
    selectedTab = .agents
  }

  func showHarnessAccounts(machineId: String, harnessId: String) {
    pendingHarnessAccountRequest = HarnessAccountSettingsRequest(
      machineId: machineId,
      harnessId: harnessId
    )
    panePath = []
    selectedTab = .agents
  }
}
