import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

enum SettingsDestination: Hashable, Identifiable {
  case root
  case section(String)
  case machines(focusedMachineID: String?)

  var id: String {
    switch self {
    case .root:
      "root"
    case .section(let section):
      section
    case let .machines(machineID):
      "machines:\(machineID ?? "all")"
    }
  }
}

/// App settings, mirroring the macOS settings window's tabs as an iOS
/// navigation list. Agents, MCPs, skills, and plugins are fleet-synced
/// config, so they sit at the top level (rendered from the selected
/// machine, whose content converges with every other machine); Machines
/// keeps what is genuinely per machine — connections, status, removal.
struct SettingsSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var path: [SettingsDestination]
  var onSectionChange: ((String) -> Void)?

  static let clientSections = [
    "root", "account", "machines", "updates", "general", "appearance", "notifications", "agents", "mcps", "skills",
    "plugins",
  ]

  init(initialDestination: SettingsDestination = .root, onSectionChange: ((String) -> Void)? = nil) {
    self.onSectionChange = onSectionChange
    switch initialDestination {
    case .root:
      _path = State(initialValue: [])
    case .machines, .section:
      _path = State(initialValue: [initialDestination])
    }
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          NavigationLink(value: SettingsDestination.section("account")) {
            Label("Account", systemImage: "person.crop.circle")
          }
          NavigationLink(value: SettingsDestination.machines(focusedMachineID: nil)) {
            Label("Machines", systemImage: "desktopcomputer")
          }
        }
        Section {
          NavigationLink(value: SettingsDestination.section("updates")) {
            // badge(0) hides itself — the ambient signal simply
            // is not there when everything is current.
            Label("Updates", systemImage: "arrow.down.circle")
              .badge(environment.updateCenter.availableCount)
          }
          NavigationLink(value: SettingsDestination.section("general")) {
            Label("Privacy & Data", systemImage: "hand.raised")
          }
          NavigationLink(value: SettingsDestination.section("appearance")) {
            Label("Appearance", systemImage: "paintpalette")
          }
          NavigationLink(value: SettingsDestination.section("notifications")) {
            Label("Notifications", systemImage: "bell")
          }
        }
        Section {
          NavigationLink(value: SettingsDestination.section("agents")) {
            Label("Harnesses", systemImage: "brain")
          }
          NavigationLink(value: SettingsDestination.section("mcps")) {
            Label("MCPs", systemImage: "puzzlepiece.extension")
          }
          NavigationLink(value: SettingsDestination.section("skills")) {
            Label("Skills", systemImage: "book.closed")
          }
          NavigationLink(value: SettingsDestination.section("plugins")) {
            Label("Plugins", systemImage: "puzzlepiece")
          }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(for: SettingsDestination.self) { destination in
        switch destination {
        case .root:
          EmptyView()
        case .section(let section):
          clientSection(section)
        case let .machines(focusedMachineID):
          MachinesSettingsScreen(focusedMachineID: focusedMachineID)
        }
      }
    }
    .onChange(of: path, initial: true) { _, path in
      let section: String
      switch path.last {
      case .section(let value): section = value
      case .machines: section = "machines"
      default: section = "root"
      }
      onSectionChange?(section)
    }
    .presentationDragIndicator(.visible)
  }
  @ViewBuilder
  private func clientSection(_ section: String) -> some View {
    switch section {
    case "account": CloudAccountScreen()
    case "updates": UpdatesSettingsScreen()
    case "general": GeneralSettingsScreen(dismissSettings: { dismiss() })
    case "appearance": AppearanceSettingsScreen()
    case "notifications": NotificationsSettingsScreen()
    case "agents": HarnessesSettingsScreen()
    case "mcps": McpSettingsScreen()
    case "skills": SkillsSettingsScreen()
    case "plugins": PluginsSettingsScreen()
    default: EmptyView()
    }
  }

}
