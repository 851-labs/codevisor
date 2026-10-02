import CodevisorClient
import SwiftUI

/// The running device's settings, as Device Hub offers them: appearance and text size,
/// accessibility, a simulated location, and sound. Settings this Mac's Xcode or the device's
/// runtime can't change are left out.
struct SimulatorSettingsView: View {
  let model: SimulatorPaneModel
  /// While a slider is held, its value stays here; the device gets it when it's let go.
  @State private var textSize: Double?
  @State private var volume: Double?

  static let contentSizes = [
    "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
    "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large",
    "accessibility-extra-extra-extra-large",
  ]

  static let locations: [(id: String, title: String)] = [
    ("none", "None"), ("apple", "Apple Park"), ("city-run", "City Run"), ("city-bicycle-ride", "City Bicycle Ride"),
    ("freeway-drive", "Freeway Drive"),
  ]

  var body: some View {
    Group {
      if let settings = model.settings {
        Form {
          appearance(settings)
          accessibility(settings)
          Section {
            Picker("Location", selection: binding(settings.location) { $0.location = $1 }) {
              ForEach(Self.locations, id: \.id) { Text($0.title).tag($0.id) }
            }
          }
          sound(settings)
        }
        .formStyle(.grouped)
      } else {
        // Just the spinner while the device answers; no form around it yet.
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    #if os(macOS)
      .frame(width: 340, height: 520)
    #else
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    #endif
    .task { await model.loadSettings() }
  }

  @ViewBuilder private func appearance(_ settings: ServerSimulatorSettings) -> some View {
    Section {
      if let appearance = settings.appearance {
        Picker("Appearance", selection: binding(appearance) { $0.appearance = $1 }) {
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        .pickerStyle(.segmented)
      }
      if let size = settings.contentSize, let index = Self.contentSizes.firstIndex(of: size) {
        LabeledContent("Text Size") {
          Slider(
            value: Binding(get: { textSize ?? Double(index) }, set: { textSize = $0 }),
            in: 0...Double(Self.contentSizes.count - 1), step: 1
          ) {
            Text("Text Size")
          } minimumValueLabel: {
            Image(systemName: "textformat.size.smaller")
          } maximumValueLabel: {
            Image(systemName: "textformat.size.larger")
          } onEditingChanged: { editing in
            guard !editing, let value = textSize else { return }
            textSize = nil
            model.change { $0.contentSize = Self.contentSizes[Int(value.rounded())] }
          }
          .labelsHidden()
          .accessibilityValue(Self.contentSizes[Int((textSize ?? Double(index)).rounded())])
        }
      }
    }
  }

  @ViewBuilder private func accessibility(_ settings: ServerSimulatorSettings) -> some View {
    Section("Accessibility") {
      if let value = settings.reduceMotion {
        settingToggle("Reduce Motion", value) { $0.reduceMotion = $1 }
      }
      if let value = settings.increaseContrast {
        settingToggle("Increase Contrast", value) { $0.increaseContrast = $1 }
      }
      if let value = settings.showBorders {
        settingToggle("Show Borders", value) { $0.showBorders = $1 }
      }
      if let value = settings.reduceTransparency {
        settingToggle("Reduce Transparency", value) { $0.reduceTransparency = $1 }
      }
      if let value = settings.voiceOver {
        settingToggle("VoiceOver", value) { $0.voiceOver = $1 }
      }
    }
  }

  @ViewBuilder private func sound(_ settings: ServerSimulatorSettings) -> some View {
    if settings.volume != nil || settings.audioOutput != nil || settings.audioInput != nil {
      Section("Sound") {
        if let level = settings.volume {
          LabeledContent("Volume") {
            Slider(
              value: Binding(get: { volume ?? level }, set: { volume = $0 }), in: 0...100
            ) {
              Text("Volume")
            } minimumValueLabel: {
              Image(systemName: "speaker.fill")
            } maximumValueLabel: {
              Image(systemName: "speaker.wave.3.fill")
            } onEditingChanged: { editing in
              guard !editing, let value = volume else { return }
              volume = nil
              model.change { $0.volume = value.rounded() }
            }
            .labelsHidden()
          }
        }
        if let route = settings.audioOutput {
          routePicker("Output", route: route, devices: settings.audioOutputs ?? []) { $0.audioOutput = $1 }
        }
        if let route = settings.audioInput {
          routePicker("Input", route: route, devices: settings.audioInputs ?? []) { $0.audioInput = $1 }
        }
      }
    }
  }

  /// The Mac's default device, then each device in that direction.
  private func routePicker(
    _ title: String, route: String, devices: [ServerSimulatorAudioDevice],
    set: @escaping (inout ServerSimulatorSettingsChange, String) -> Void
  ) -> some View {
    Picker(title, selection: binding(route, set: set)) {
      Text("System").tag(ServerSimulatorSettings.systemAudioRoute)
      if !devices.isEmpty { Divider() }
      ForEach(devices) { Text($0.name).tag($0.uid) }
      // A device that's since gone keeps its name off the list but still shows as chosen.
      if route != ServerSimulatorSettings.systemAudioRoute, !devices.contains(where: { $0.uid == route }) {
        Text("Unavailable Device").tag(route)
      }
    }
  }

  /// A Mac's switch can keep drawing its old state when the value changes underneath it (as an
  /// optimistic change or the device's answer does); a new switch per value always draws right.
  private func settingToggle(
    _ title: String, _ value: Bool, set: @escaping (inout ServerSimulatorSettingsChange, Bool) -> Void
  ) -> some View {
    Toggle(title, isOn: binding(value, set: set)).id("\(title).\(value)")
  }

  private func binding<Value>(
    _ value: Value, set: @escaping (inout ServerSimulatorSettingsChange, Value) -> Void
  ) -> Binding<Value> {
    Binding(get: { value }, set: { newValue in model.change { set(&$0, newValue) } })
  }
}
