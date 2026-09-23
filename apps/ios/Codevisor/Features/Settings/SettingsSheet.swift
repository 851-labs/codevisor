import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
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
  @Environment(\.openURL) private var openURL
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var path: [SettingsDestination]
  /// The regular-width sidebar's selection.
  @State private var selection: SettingsDestination?
  @State private var showsEmailFallback = false
  var onSectionChange: ((String) -> Void)?

  private static let supportEmail = "hello@codevisor.dev"

  private var appVersion: String {
    let version = AppUpdateModel.bundleVersion()
    guard let buildNumber = AppUpdateModel.bundleBuildNumber() else { return version }
    return "\(version) (\(buildNumber))"
  }

  static let clientSections = [
    "root", "account", "machines", "updates", "general", "appearance", "agents", "mcps", "skills",
    "plugins",
  ]

  init(initialDestination: SettingsDestination = .root, onSectionChange: ((String) -> Void)? = nil) {
    self.onSectionChange = onSectionChange
    switch initialDestination {
    case .root:
      _path = State(initialValue: [])
      // The regular-width sidebar opens on Account, highlighted.
      _selection = State(initialValue: .section("account"))
    case .machines, .section:
      _path = State(initialValue: [initialDestination])
      _selection = State(initialValue: initialDestination)
    }
  }

  var body: some View {
    Group {
      // Regular width (iPad) shows the sections beside their content, as
      // the macOS settings window does; compact keeps the pushed list.
      if horizontalSizeClass == .regular {
        splitSettings
      } else {
        stackSettings
      }
    }
    .alert("Can’t Open Email", isPresented: $showsEmailFallback) {
      Button("Copy Email Address") {
        UIPasteboard.general.string = Self.supportEmail
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Email us at \(Self.supportEmail). Copy the address to use it in your preferred email app.")
    }
    .onChange(of: currentDestination, initial: true) { _, destination in
      let section: String
      switch destination {
      case .section(let value): section = value
      case .machines: section = "machines"
      default: section = "root"
      }
      onSectionChange?(section)
    }
    .presentationSizing(.page)
    .presentationDragIndicator(.visible)
  }

  private var currentDestination: SettingsDestination? {
    horizontalSizeClass == .regular ? selectedDetail : path.last
  }

  private var selectedDetail: SettingsDestination {
    selection ?? .section("account")
  }

  private var stackSettings: some View {
    NavigationStack(path: $path) {
      List { settingsSections }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { doneButton }
        .navigationDestination(for: SettingsDestination.self) { destination in
          destinationScreen(destination)
        }
    }
  }

  private var splitSettings: some View {
    NavigationSplitView {
      List(selection: $selection) { settingsSections }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    } detail: {
      NavigationStack {
        destinationScreen(selectedDetail)
          .toolbar { doneButton }
      }
      // A new section starts at its own root.
      .id(selectedDetail)
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var doneButton: some ToolbarContent {
    ToolbarItem(placement: .confirmationAction) {
      Button("Done") { dismiss() }
    }
  }

  @ViewBuilder
  private func destinationScreen(_ destination: SettingsDestination) -> some View {
    switch destination {
    case .root:
      EmptyView()
    case .section(let section):
      clientSection(section)
    case let .machines(focusedMachineID):
      MachinesSettingsScreen(focusedMachineID: focusedMachineID)
    }
  }

  @ViewBuilder
  private var settingsSections: some View {
    Section {
      NavigationLink(value: SettingsDestination.section("account")) {
        settingsLabel("Account", systemImage: "person.crop.circle")
      }
      NavigationLink(value: SettingsDestination.machines(focusedMachineID: nil)) {
        settingsLabel("Machines", systemImage: "desktopcomputer")
      }
    }
    Section {
      NavigationLink(value: SettingsDestination.section("updates")) {
        // badge(0) hides itself — the ambient signal simply
        // is not there when everything is current.
        settingsLabel("Updates", systemImage: "arrow.down.circle")
          .badge(environment.updateCenter.availableCount)
      }
      NavigationLink(value: SettingsDestination.section("general")) {
        settingsLabel("Privacy & Data", systemImage: "hand.raised")
      }
      NavigationLink(value: SettingsDestination.section("appearance")) {
        settingsLabel("Appearance", systemImage: "paintpalette")
      }
    }
    Section {
      NavigationLink(value: SettingsDestination.section("agents")) {
        settingsLabel("Harnesses", systemImage: "brain")
      }
      NavigationLink(value: SettingsDestination.section("mcps")) {
        settingsLabel("MCPs", systemImage: "puzzlepiece.extension")
      }
      NavigationLink(value: SettingsDestination.section("skills")) {
        settingsLabel("Skills", systemImage: "book.closed")
      }
      NavigationLink(value: SettingsDestination.section("plugins")) {
        settingsLabel("Plugins", systemImage: "puzzlepiece")
      }
    }
    Section {
      Button {
        openURL(URL(string: "mailto:\(Self.supportEmail)?subject=Codevisor%20iOS%20Support")!) {
          accepted in
          showsEmailFallback = !accepted
        }
      } label: {
        externalLinkLabel("Contact Support", systemImage: "envelope")
      }
      .accessibilityIdentifier("settings.contactSupport")
      .accessibilityHint("Opens your email app")
      .contextMenu {
        Button("Copy Email Address", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = Self.supportEmail
        }
      }
      Link(destination: URL(string: "https://www.codevisor.dev/terms")!) {
        externalLinkLabel("Terms of Use", systemImage: "doc.text")
      }
      .accessibilityIdentifier("settings.termsOfUse")
      .accessibilityHint("Opens in your browser")
      Link(destination: AIDataSharingConsent.privacyPolicyURL) {
        externalLinkLabel("Privacy Policy", systemImage: "hand.raised")
      }
      .accessibilityIdentifier("settings.privacyPolicy")
      .accessibilityHint("Opens in your browser")
    } footer: {
      Text(appVersion)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .accessibilityIdentifier("settings.appVersion")
    }
  }

  private func settingsLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
    Label {
      Text(title)
        .foregroundStyle(.primary)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
    }
  }

  private func externalLinkLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
    HStack {
      settingsLabel(title, systemImage: systemImage)
      Spacer()
      Image(systemName: "arrow.up.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func clientSection(_ section: String) -> some View {
    switch section {
    case "account": CloudAccountScreen()
    case "updates": UpdatesSettingsScreen()
    case "general": GeneralSettingsScreen(dismissSettings: { dismiss() })
    case "appearance": AppearanceSettingsScreen()
    case "agents": HarnessesSettingsScreen()
    case "mcps": McpSettingsScreen()
    case "skills": SkillsSettingsScreen()
    case "plugins": PluginsSettingsScreen()
    default: EmptyView()
    }
  }

}
