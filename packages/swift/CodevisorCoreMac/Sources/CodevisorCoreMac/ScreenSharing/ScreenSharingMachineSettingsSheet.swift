import SwiftUI

public struct ScreenSharingMachineSettings: Equatable, Sendable {
  public struct Display: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
  }

  public struct Sound: Equatable, Sendable {
    public var enabled: Bool
    public var volume: Double
    public init(enabled: Bool = true, volume: Double = 1) { self.enabled = enabled; self.volume = volume }
  }

  public var name: String
  public var connection: String
  public var address: String?
  public var dynamicResolution: Bool?
  public var dynamicResolutionNote: String?
  public var highDynamicRange: Bool?
  public var highDynamicRangeNote: String?
  public var displays: [Display]
  public var preferredDisplayId: String?
  public var lastConnected: Date?
  public var sound: Sound?

  public init(
    name: String, connection: String, address: String? = nil, dynamicResolution: Bool? = nil,
    displays: [Display] = [], preferredDisplayId: String? = nil, lastConnected: Date? = nil, sound: Sound? = nil
  ) {
    self.sound = sound
    self.name = name; self.connection = connection; self.address = address
    self.dynamicResolution = dynamicResolution; self.displays = displays
    self.preferredDisplayId = preferredDisplayId; self.lastConnected = lastConnected
  }
}

public struct ScreenSharingMachineSettingsChanges: Equatable, Sendable {
  public var dynamicResolution: Bool?
  public var highDynamicRange: Bool?
  public var preferredDisplayId: String?
  public var sound: ScreenSharingMachineSettings.Sound?

  public init(
    dynamicResolution: Bool? = nil, highDynamicRange: Bool? = nil, preferredDisplayId: String? = nil,
    sound: ScreenSharingMachineSettings.Sound? = nil
  ) {
    self.sound = sound
    self.highDynamicRange = highDynamicRange
    self.dynamicResolution = dynamicResolution; self.preferredDisplayId = preferredDisplayId
  }

  public var isEmpty: Bool { self == Self() }
  public var reconnects: Bool { preferredDisplayId != nil }
}

public struct ScreenSharingMachineSettingsDraft: Equatable, Sendable {
  public var settings: ScreenSharingMachineSettings

  public init(_ settings: ScreenSharingMachineSettings) { self.settings = settings }

  public func changes(from original: ScreenSharingMachineSettings) -> ScreenSharingMachineSettingsChanges {
    var changes = ScreenSharingMachineSettingsChanges()
    if settings.dynamicResolution != original.dynamicResolution {
      changes.dynamicResolution = settings.dynamicResolution
    }
    if settings.highDynamicRange != original.highDynamicRange {
      changes.highDynamicRange = settings.highDynamicRange
    }
    if settings.preferredDisplayId != original.preferredDisplayId, let display = settings.preferredDisplayId,
      settings.displays.contains(where: { $0.id == display })
    {
      changes.preferredDisplayId = display
    }
    if let sound = settings.sound, sound != original.sound { changes.sound = sound }
    return changes
  }
}

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
        display
        if draft.settings.sound != nil { sound }
      }
      .formStyle(.grouped)
      footer
    }
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var sound: some View {
    Section("Sound") {
      Toggle(
        "Play this machine's sound",
        isOn: Binding(get: { draft.settings.sound?.enabled ?? false }, set: { draft.settings.sound?.enabled = $0 }))
      LabeledContent("Volume") {
        Slider(
          value: Binding(get: { draft.settings.sound?.volume ?? 1 }, set: { draft.settings.sound?.volume = $0 }),
          in: 0...1
        ) {
          Text("Volume")
        } minimumValueLabel: {
          Image(systemName: "speaker.fill")
        } maximumValueLabel: {
          Image(systemName: "speaker.wave.3.fill")
        }
        .labelsHidden()
      }
      .disabled(draft.settings.sound?.enabled != true)
    }
  }

  @ViewBuilder private var display: some View {
    if draft.settings.dynamicResolution != nil || draft.settings.highDynamicRange != nil
      || draft.settings.displays.count > 1
    {
      Section("Display") {
        if draft.settings.dynamicResolution != nil {
          Toggle(
            "Dynamic Resolution",
            isOn: Binding(
              get: { draft.settings.dynamicResolution ?? false }, set: { draft.settings.dynamicResolution = $0 })
          )
          .disabled(draft.settings.dynamicResolutionNote != nil)
          if let note = draft.settings.dynamicResolutionNote {
            Text(note).font(.callout).foregroundStyle(.secondary)
          }
        }
        if draft.settings.highDynamicRange != nil {
          Toggle(
            "High Dynamic Range (HDR)",
            isOn: Binding(
              get: { draft.settings.highDynamicRange ?? false }, set: { draft.settings.highDynamicRange = $0 }))
          if draft.settings.highDynamicRange == true, let note = draft.settings.highDynamicRangeNote {
            Text(note).font(.callout).foregroundStyle(.secondary)
          }
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
    }
    .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4)
  }
}

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
