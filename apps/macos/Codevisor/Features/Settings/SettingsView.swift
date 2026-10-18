import SwiftUI
import AppKit
import CodevisorCore
import os
import UniformTypeIdentifiers
import UserNotifications
import CodevisorUI

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

private struct SettingsBackForwardControl: View {
  @Bindable private var router = SettingsRouter.shared

  var body: some View {
    ControlGroup {
      Button {
        router.goBack()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .disabled(!router.canGoBack)
      .help("Back")
      .keyboardShortcut("[", modifiers: .command)

      Button {
        router.goForward()
      } label: {
        Label("Forward", systemImage: "chevron.right")
      }
      .disabled(!router.canGoForward)
      .help("Forward")
      .keyboardShortcut("]", modifiers: .command)
    }
    .controlGroupStyle(.navigation)
  }
}

private struct SettingsNavigationToolbar: ViewModifier {
  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .navigation) {
        SettingsBackForwardControl()
      }
    }
  }
}

extension View {
  fileprivate func settingsNavigationToolbar() -> some View {
    modifier(SettingsNavigationToolbar())
  }
}

private struct SettingsMachineIdKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  var settingsMachineId: String? {
    get { self[SettingsMachineIdKey.self] }
    set { self[SettingsMachineIdKey.self] = newValue }
  }
}

struct SettingsView: View {
  @Bindable private var router = SettingsRouter.shared
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    NavigationSplitView {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(SettingsTab.allCases) { tab in
            SettingsSidebarRow(
              tab: tab,
              isSelected: router.selectedTab == tab,
              badgeCount: tab == .updates ? environment.updateCenter.availableCount : 0
            ) {
              selectSidebarTab(tab)
            }
          }
        }
        .padding(8)
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .themedSurface(.sidebar)
      .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 240)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      NavigationStack(path: $router.panePath) {
        detailRoot
          .settingsNavigationToolbar()
          .navigationDestination(for: SettingsPaneRoute.self) { route in
            switch route {
            case let .project(groupId):
              ProjectSettingsDetailView(groupId: groupId)
                .navigationBarBackButtonHidden(true)
                .settingsNavigationToolbar()
            }
          }
      }
    }
    .onChange(of: router.currentLocation) { previous, current in
      if let pending = router.pendingAppliedLocation {
        if current == pending { router.pendingAppliedLocation = nil }
        return
      }
      router.recordNavigation(from: previous)
    }
    .frame(minWidth: 780, idealWidth: 780, minHeight: 560, idealHeight: 560)
    .settingsWindowToolbarStyle()
  }

  private func selectSidebarTab(_ tab: SettingsTab) {
    if tab != router.selectedTab { router.panePath = [] }
    if tab == .projects { router.projectCreationMachineId = nil }
    router.selectedTab = tab
  }

  @ViewBuilder
  private var detailRoot: some View {
    switch router.selectedTab {
    case .updates:
      UpdateCenterView()
        .navigationTitle("Updates")
    case .general:
      GeneralSettingsView()
        .navigationTitle("Privacy & Data")
    case .notifications:
      NotificationsSettingsView()
        .navigationTitle("Notifications")
    case .shortcuts:
      ShortcutsSettingsView()
        .navigationTitle("Shortcuts")
    case .agents:
      HarnessesSettingsView()
        .navigationTitle("Harnesses")
    case .mcps:
      McpSettingsView()
        .navigationTitle("MCP Servers")
    case .skills:
      SkillsSettingsView()
        .navigationTitle("Skills")
    case .plugins:
      PluginsSettingsView()
        .navigationTitle("Plugins")
    case .projects:
      ProjectsSettingsView()
        .navigationTitle("Projects")
    case .account:
      CloudSettingsView()
        .navigationTitle("Account")
    case .machines:
      MachinesSettingsView()
        .navigationTitle("Machines")
    case .developer:
      DeveloperSettingsView()
        .navigationTitle("Developer")
    }
  }
}

private struct SettingsSidebarRow: View {
  let tab: SettingsTab
  let isSelected: Bool
  let badgeCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: tab.systemImage)
          .frame(width: 18)
          .foregroundStyle(.secondary)
        Text(tab.title)
          .lineLimit(1)
        Spacer(minLength: 4)
        if badgeCount > 0 {
          Text(badgeCount, format: .number)
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .sidebarRowHover(isSelected: isSelected)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview("Settings") {
  SettingsView()
    .environment(AppEnvironment.preview())
}
