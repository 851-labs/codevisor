import SwiftUI

/// One machine's Screen Sharing settings, in one grouped form like Apple's
/// Screen Sharing (851-2367). How the machine is reached comes from where it's
/// defined (the machine's codevisor-server in the app, the rig's catalog) and
/// is read-only here; what the viewer chooses is editable. A saved password is
/// never shown, only replaced or forgotten.
public struct ScreenSharingMachineSettings: Equatable, Sendable {
  public struct Display: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
  }

  /// Mac account sign-in for a server that asks for it (macOS Screen Sharing over VNC).
  public struct SignIn: Equatable, Sendable {
    public var userName: String
    public var hasSavedPassword: Bool
    public init(userName: String, hasSavedPassword: Bool) {
      self.userName = userName; self.hasSavedPassword = hasSavedPassword
    }
  }

  public var name: String
  /// How the machine is reached, e.g. "Codevisor on this Mac" or "VNC".
  public var connection: String
  public var address: String?
  /// Nil when this machine has no sign-in of its own (the app's machines sign in through codevisor-server).
  public var signIn: SignIn?
  /// Nil when the connection can't resize the remote desktop.
  public var dynamicResolution: Bool?
  public var displays: [Display]
  public var preferredDisplayId: String?
  public var lastConnected: Date?

  public init(
    name: String, connection: String, address: String? = nil, signIn: SignIn? = nil, dynamicResolution: Bool? = nil,
    displays: [Display] = [], preferredDisplayId: String? = nil, lastConnected: Date? = nil
  ) {
    self.name = name; self.connection = connection; self.address = address; self.signIn = signIn
    self.dynamicResolution = dynamicResolution; self.displays = displays
    self.preferredDisplayId = preferredDisplayId; self.lastConnected = lastConnected
  }
}

/// What Done changes. Nil and `.keep` leave a setting as it was.
public struct ScreenSharingMachineSettingsChanges: Equatable, Sendable {
  public enum Password: Equatable, Sendable {
    case keep, forget
    case replace(String)
  }

  public var dynamicResolution: Bool?
  public var preferredDisplayId: String?
  public var userName: String?
  public var password: Password = .keep

  public init(
    dynamicResolution: Bool? = nil, preferredDisplayId: String? = nil, userName: String? = nil,
    password: Password = .keep
  ) {
    self.dynamicResolution = dynamicResolution; self.preferredDisplayId = preferredDisplayId
    self.userName = userName; self.password = password
  }

  public var isEmpty: Bool { self == Self() }
  /// A new display or new credentials take a new connection; the rest applies as it is.
  public var reconnects: Bool { preferredDisplayId != nil || userName != nil || password != .keep }
}

/// The form's editable copy of the settings, and what it changes against the original.
public struct ScreenSharingMachineSettingsDraft: Equatable, Sendable {
  public var settings: ScreenSharingMachineSettings
  /// The password typed after Change…; empty keeps the saved one.
  public var newPassword = ""
  public var changingPassword = false
  public var forgettingPassword = false

  public init(_ settings: ScreenSharingMachineSettings) { self.settings = settings }

  public func changes(from original: ScreenSharingMachineSettings) -> ScreenSharingMachineSettingsChanges {
    var changes = ScreenSharingMachineSettingsChanges()
    if settings.dynamicResolution != original.dynamicResolution {
      changes.dynamicResolution = settings.dynamicResolution
    }
    if settings.preferredDisplayId != original.preferredDisplayId, let display = settings.preferredDisplayId,
      settings.displays.contains(where: { $0.id == display })
    {
      changes.preferredDisplayId = display
    }
    if let signIn = settings.signIn, let before = original.signIn {
      let userName = signIn.userName.trimmingCharacters(in: .whitespaces)
      if userName != before.userName { changes.userName = userName }
      if forgettingPassword {
        changes.password = before.hasSavedPassword ? .forget : .keep
      } else if changingPassword, !newPassword.isEmpty {
        changes.password = .replace(newPassword)
      }
    }
    return changes
  }
}

/// The sheet: a grouped form, Cancel and Done. Done hands back only what changed.
public struct ScreenSharingMachineSettingsSheet: View {
  private let original: ScreenSharingMachineSettings
  private let onDone: (ScreenSharingMachineSettingsChanges) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ScreenSharingMachineSettingsDraft

  public init(
    settings: ScreenSharingMachineSettings, onDone: @escaping (ScreenSharingMachineSettingsChanges) -> Void
  ) {
    original = settings
    self.onDone = onDone
    _draft = State(initialValue: ScreenSharingMachineSettingsDraft(settings))
  }

  public var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Machine") {
          LabeledContent("Name", value: draft.settings.name)
        }
        Section("Connection") {
          LabeledContent("Reached through", value: draft.settings.connection)
          if let address = draft.settings.address { LabeledContent("Address", value: address) }
        }
        if draft.settings.signIn != nil { signIn }
        display
      }
      .formStyle(.grouped)
      footer
    }
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var signIn: some View {
    Section {
      TextField(
        "User name",
        text: Binding(
          get: { draft.settings.signIn?.userName ?? "" }, set: { draft.settings.signIn?.userName = $0 }))
      LabeledContent("Password") {
        HStack {
          Text(passwordState).foregroundStyle(.secondary)
          if !draft.changingPassword, !draft.forgettingPassword {
            Button("Change…") { draft.changingPassword = true }
            if original.signIn?.hasSavedPassword == true {
              Button("Forget") { draft.forgettingPassword = true }
            }
          } else {
            Button("Keep") {
              draft.changingPassword = false; draft.forgettingPassword = false; draft.newPassword = ""
            }
          }
        }
      }
      if draft.changingPassword {
        SecureField("New password", text: $draft.newPassword)
      }
    } header: {
      Text("Sign-in")
    } footer: {
      Text("The password is kept in the Keychain and is never shown.").foregroundStyle(.secondary)
    }
  }

  private var passwordState: String {
    if draft.forgettingPassword { return "Will be forgotten" }
    if draft.changingPassword { return "Replacing" }
    return original.signIn?.hasSavedPassword == true ? "Saved" : "Asked when connecting"
  }

  @ViewBuilder private var display: some View {
    if draft.settings.dynamicResolution != nil || draft.settings.displays.count > 1 {
      Section("Display") {
        if draft.settings.dynamicResolution != nil {
          Toggle(
            "Dynamic Resolution",
            isOn: Binding(
              get: { draft.settings.dynamicResolution ?? false }, set: { draft.settings.dynamicResolution = $0 }))
        }
        if draft.settings.displays.count > 1 {
          Picker("Display", selection: $draft.settings.preferredDisplayId) {
            ForEach(draft.settings.displays) { Text($0.name).tag(Optional($0.id)) }
          }
        }
      }
    }
  }

  private var footer: some View {
    let changes = draft.changes(from: original)
    return HStack {
      if let last = original.lastConnected {
        Text("Last connected \(last.formatted(.relative(presentation: .named)))")
          .font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
      Button(changes.reconnects ? "Reconnect" : "Done") {
        if !changes.isEmpty { onDone(changes) }
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .disabled(draft.changingPassword && draft.newPassword.isEmpty)
    }
    .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4)
  }
}

/// The toolbar's gear, right of the Connection Details ⓘ in the app and the rig.
public struct ScreenSharingMachineSettingsButton: View {
  private let settings: () -> ScreenSharingMachineSettings
  private let apply: (ScreenSharingMachineSettingsChanges) -> Void
  @State private var presented: ScreenSharingMachineSettings?

  public init(
    settings: @escaping () -> ScreenSharingMachineSettings,
    apply: @escaping (ScreenSharingMachineSettingsChanges) -> Void
  ) {
    self.settings = settings; self.apply = apply
  }

  public var body: some View {
    Button {
      presented = settings()
    } label: {
      Image(systemName: "gearshape")
    }
    .accessibilityLabel("Machine Settings")
    .help("Machine Settings")
    .sheet(item: $presented) { settings in
      ScreenSharingMachineSettingsSheet(settings: settings, onDone: apply)
    }
  }
}

extension ScreenSharingMachineSettings: Identifiable {
  public var id: String { name }
}
