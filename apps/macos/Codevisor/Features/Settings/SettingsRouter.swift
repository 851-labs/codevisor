import AppKit
import CodevisorCore
import Observation

enum SettingsTab: String, CaseIterable, Identifiable {
  case general, account, updates, notifications
  case shortcuts
  case agents, mcps, skills, plugins
  case projects, machines
  case developer

  var id: String { rawValue }

  var title: String {
    switch self {
    case .account: "Account"
    case .updates: "Updates"
    case .general: "General"
    case .notifications: "Notifications"
    case .shortcuts: "Shortcuts"
    case .agents: "Harnesses"
    case .mcps: "MCP Servers"
    case .skills: "Skills"
    case .plugins: "Plugins"
    case .projects: "Projects"
    case .machines: "Machines"
    case .developer: "Developer"
    }
  }

  var systemImage: String {
    switch self {
    case .account: "person.crop.circle"
    case .updates: "arrow.down.circle"
    case .general: "gear"
    case .notifications: "bell"
    case .shortcuts: "keyboard"
    case .agents: "brain"
    case .mcps: "puzzlepiece.extension"
    case .skills: "book.closed"
    case .plugins: "puzzlepiece"
    case .projects: "folder"
    case .machines: "desktopcomputer"
    case .developer: "hammer"
    }
  }
}

enum SettingsPaneRoute: Hashable {
  case project(ProjectGroup.ID)
}

struct SettingsLocation: Equatable {
  var tab: SettingsTab
  var panePath: [SettingsPaneRoute]
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

  private func apply(_ location: SettingsLocation) {
    pendingAppliedLocation = location
    selectedTab = location.tab
    panePath = location.panePath
  }

  func showMachines() {
    panePath = []
    selectedTab = .machines
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

  func showPlugins(machineId: String? = nil) {
    _ = machineId
    panePath = []
    selectedTab = .plugins
  }

  var pendingPluginInstallSource: String?
}
