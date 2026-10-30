import SwiftUI
import AppKit
import CodevisorCore
import os
import UniformTypeIdentifiers
import UserNotifications
import CodevisorUI

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
  @State private var plugins = PluginSettingsModel()

  var body: some View {
    NavigationSplitView {
      ScrollView {
        VStack(spacing: 14) {
          ForEach(SettingsTab.sidebarGroups, id: \.self) { group in
            VStack(spacing: 2) {
              ForEach(group) { tab in
                SettingsSidebarRow(
                  tab: tab,
                  isSelected: router.selectedTab == tab,
                  badgeCount: tab == .updates ? environment.updateCenter.availableCount : 0
                ) {
                  selectSidebarTab(tab)
                }
              }
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
            case let .sandbox(page):
              SandboxSettingsPageView(
                page: page, model: environment.sandboxSettings,
                client: environment.machines.client(for: CodevisorMachine.local.id),
                navigate: router.navigate
              )
              .navigationBarBackButtonHidden(true)
              .settingsNavigationToolbar()
            case .pluginCatalog:
              PluginCatalogPage(catalog: pluginCatalog, plugins: plugins, client: localClient)
                .navigationBarBackButtonHidden(true)
                .settingsNavigationToolbar()
            case let .plugin(name):
              McpPluginDetailView(entryName: name, plugins: plugins)
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

  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  private var pluginCatalog: PluginCatalogModel {
    plugins.catalog(using: localClient)
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
        .navigationTitle("General")
    case .notifications:
      NotificationsSettingsView()
        .navigationTitle("Notifications")
    case .shortcuts:
      ShortcutsSettingsView()
        .navigationTitle("Shortcuts")
    case .agents:
      HarnessesSettingsView()
        .navigationTitle("Harnesses")
    case .skills:
      SkillsSettingsView()
        .navigationTitle("Skills")
    case .plugins:
      McpSettingsView(plugins: plugins)
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
    case .sandboxes:
      SandboxesSettingsView(model: environment.sandboxSettings)
        .navigationTitle("Sandboxes")
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
        SettingsIconTile(tab.icon, size: 20)
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
