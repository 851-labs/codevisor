import CodevisorClient
import SwiftUI

/// The running device's settings, as Device Hub offers them: appearance, Liquid Glass, color
/// filter and text size, accessibility, a simulated location, and sound. Settings this Mac's
/// Xcode or the device's runtime can't change are left out.
struct SimulatorSettingsView: View {
  let model: SimulatorPaneModel

  static let contentSizes = [
    "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
    "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large",
    "accessibility-extra-extra-extra-large",
  ]

  /// Device Hub's color filters, by CoreDevice's name for each.
  static let colorFilters: [(id: String, title: String)] = [
    ("none", "None"), ("protanopia", "Red/Green (Protanopia)"), ("deuteranopia", "Green/Red (Deuteranopia)"),
    ("tritanopia", "Blue/Yellow (Tritanopia)"), ("grayscale", "Grayscale"),
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
      .frame(width: 340, height: 600)
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
      if let opacity = settings.liquidGlass {
        SettingSlider(
          "Liquid Glass", value: opacity, in: 0...1, low: ("circle.dotted", "Clear"), high: ("circle.fill", "Tinted"),
          describe: { $0.formatted(.percent.precision(.fractionLength(0))) }
        ) { value in
          model.change { $0.liquidGlass = (value * 100).rounded() / 100 }
        }
      }
      if let filter = settings.colorFilter {
        Picker("Color Filter", selection: binding(filter) { $0.colorFilter = $1 }) {
          ForEach(Self.colorFilters, id: \.id) { Text($0.title).tag($0.id) }
        }
      }
      if let size = settings.contentSize, let index = Self.contentSizes.firstIndex(of: size) {
        SettingSlider(
          "Text Size", value: Double(index), in: 0...Double(Self.contentSizes.count - 1), step: 1,
          low: ("textformat.size.smaller", "Smaller"), high: ("textformat.size.larger", "Larger"),
          describe: { Self.contentSizes[Int($0.rounded())] }
        ) { value in
          model.change { $0.contentSize = Self.contentSizes[Int(value.rounded())] }
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
          SettingSlider(
            "Volume", value: level, in: 0...100, low: ("speaker.fill", "Quieter"),
            high: ("speaker.wave.3.fill", "Louder"),
            describe: { "\(Int($0.rounded()))%" }
          ) { value in
            model.change { $0.volume = value.rounded() }
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

/// A setting on a slider. Dragged, the device gets the value once it's let go, not at every step
/// on the way; stepped with the keyboard or VoiceOver (no drag), each step goes straight through.
private struct SettingSlider: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let step: Double?
  /// The symbol at each end, and what it's called aloud.
  let low: (symbol: String, name: String)
  let high: (symbol: String, name: String)
  let describe: (Double) -> String
  let commit: (Double) -> Void
  @State private var held: Double?
  @State private var dragging = false

  init(
    _ title: String, value: Double, in range: ClosedRange<Double>, step: Double? = nil, low: (String, String),
    high: (String, String),
    describe: @escaping (Double) -> String, commit: @escaping (Double) -> Void
  ) {
    self.title = title
    self.value = value
    self.range = range
    self.step = step
    self.low = low
    self.high = high
    self.describe = describe
    self.commit = commit
  }

  var body: some View {
    let shown = held ?? value
    let binding = Binding(
      get: { shown },
      set: { new in
        if dragging { held = new } else { commit(new) }
      })
    LabeledContent(title) {
      Group {
        if let step {
          Slider(value: binding, in: range, step: step) {
            Text(title)
          } minimumValueLabel: {
            Image(systemName: low.symbol).accessibilityLabel(low.name)
          } maximumValueLabel: {
            Image(systemName: high.symbol).accessibilityLabel(high.name)
          } onEditingChanged: {
            editingChanged($0)
          }
        } else {
          Slider(value: binding, in: range) {
            Text(title)
          } minimumValueLabel: {
            Image(systemName: low.symbol).accessibilityLabel(low.name)
          } maximumValueLabel: {
            Image(systemName: high.symbol).accessibilityLabel(high.name)
          } onEditingChanged: {
            editingChanged($0)
          }
        }
      }
      .labelsHidden()
      .accessibilityValue(describe(shown))
    }
  }

  private func editingChanged(_ editing: Bool) {
    dragging = editing
    guard !editing, let value = held else { return }
    held = nil
    commit(value)
  }
}
