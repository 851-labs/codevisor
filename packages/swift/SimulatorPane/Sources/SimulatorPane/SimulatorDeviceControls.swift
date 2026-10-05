import CodevisorClient
import ScreenSharing
import SwiftUI

/// Presses the device's own buttons, as a click: down, a short hold the guest registers as a
/// press, then up.
@MainActor
enum SimulatorDeviceControls {
  static func press(_ name: String, on model: SimulatorPaneModel) {
    model.send(.button(name: name, down: true))
    Task {
      try? await Task.sleep(for: .milliseconds(100))
      model.send(.button(name: name, down: false))
    }
  }
}

/// Home, or on an Apple TV the remote's Back, TV and Play/Pause. Shortcuts match Simulator's.
struct SimulatorHomeButtons: View {
  let model: SimulatorPaneModel
  let device: ServerSimulatorDevice

  var body: some View {
    if device.deviceType.productFamily == "Apple TV" {
      Button("Back", systemImage: "chevron.backward") { SimulatorDeviceControls.press("menu", on: model) }
        .help("Back")
      Button("TV", systemImage: "tv") { SimulatorDeviceControls.press("home", on: model) }
        .help("TV")
        .keyboardShortcut("h", modifiers: [.command, .shift])
      Button("Play/Pause", systemImage: "playpause.fill") { SimulatorDeviceControls.press("play-pause", on: model) }
        .help("Play/Pause")
    } else {
      Button("Home", systemImage: "square.grid.3x3.fill") { SimulatorDeviceControls.press("home", on: model) }
        .help("Home (⇧⌘H)")
        .keyboardShortcut("h", modifiers: [.command, .shift])
    }
  }
}

/// Saves (Mac) or shares (iPhone, iPad) what the device shows.
struct SimulatorScreenshotButton: View {
  let model: SimulatorPaneModel
  let device: ServerSimulatorDevice
  let onScreenshot: (Data, String) -> Void
  @State private var capturing = false

  var body: some View {
    Button("Screenshot", systemImage: "camera.viewfinder") {
      capturing = true
      Task {
        defer { capturing = false }
        guard let data = await model.screenshot() else { return }
        onScreenshot(data, device.name)
      }
    }
    .help("Screenshot (⌘S)")
    .keyboardShortcut("s", modifiers: .command)
    .disabled(capturing)
  }
}

/// Turns the device a quarter left (as Device Hub's button does); its context menu turns it
/// either way.
struct SimulatorRotateButton: View {
  let model: SimulatorPaneModel

  /// Whether the device turns at all: not an Apple TV, and only a Vision Pro that says it can.
  static func shown(model: SimulatorPaneModel, device: ServerSimulatorDevice) -> Bool {
    let family = device.deviceType.productFamily
    let canRotate = model.deviceState?.canRotate
    if family == "Apple TV" || canRotate == false { return false }
    return family != "Apple Vision" || canRotate == true
  }

  var body: some View {
    Button("Rotate", systemImage: "rectangle.portrait.rotate") { model.rotate(clockwise: false) }
      .keyboardShortcut(.leftArrow, modifiers: .command)
      .help("Rotate (⌘← ⌘→)")
      .contextMenu {
        Button("Rotate Left", systemImage: "rotate.left") { model.rotate(clockwise: false) }
        Button("Rotate Right", systemImage: "rotate.right") { model.rotate(clockwise: true) }
      }
      // ⌘→ turns the other way without a visible button of its own.
      .background {
        Button("Rotate Right") { model.rotate(clockwise: true) }
          .keyboardShortcut(.rightArrow, modifiers: .command)
          .hidden()
      }
  }
}

#if os(macOS)
  /// Device Hub's action bar: one glass capsule of icon buttons (Home, Screenshot), and Rotate in
  /// a glass circle of its own beside it, or in a capsule with a foldable's postures.
  struct SimulatorActionBar: View {
    let model: SimulatorPaneModel
    let device: ServerSimulatorDevice
    let onScreenshot: (Data, String) -> Void

    var body: some View {
      // Shapes blend when closer than the container's spacing; the 10-point gap keeps them apart.
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 10) {
          HStack(spacing: 0) {
            SimulatorHomeButtons(model: model, device: device)
            SimulatorScreenshotButton(model: model, device: device, onScreenshot: onScreenshot)
          }
          .padding(.horizontal, 2)
          .glassEffect(.regular.interactive(), in: .capsule)
          let rotates = SimulatorRotateButton.shown(model: model, device: device)
          if model.deviceState?.postures.isEmpty == false {
            // A foldable's Rotate shares a capsule with its postures, a rule between them.
            HStack(spacing: 0) {
              if rotates {
                SimulatorRotateButton(model: model)
                Divider().frame(height: 18).padding(.horizontal, 4)
              }
              SimulatorPostureButtons(model: model)
            }
            .padding(.horizontal, 2)
            .glassEffect(.regular.interactive(), in: .capsule)
          } else if rotates {
            SimulatorRotateButton(model: model)
              .glassEffect(.regular.interactive(), in: .circle)
          }
        }
      }
      .labelStyle(SimulatorActionBarLabelStyle())
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
    }
  }

  /// An action bar button's symbol in a 34×36 cell (Device Hub's size) that clicks anywhere
  /// in it and lights up under the pointer.
  struct SimulatorActionBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      Cell(configuration: configuration)
    }

    private struct Cell: View {
      let configuration: LabelStyleConfiguration
      @State private var hovering = false

      var body: some View {
        // The title stays in the label (hidden), so the button keeps its accessibility name.
        Label {
          configuration.title
        } icon: {
          configuration.icon
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 14, weight: .medium))
        // Device Hub's highlight is a 28-point circle inset in the capsule, not the whole cell.
        .frame(width: 28, height: 28)
        .background(.primary.opacity(hovering ? 0.1 : 0), in: .circle)
        .frame(width: 34, height: 36)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
      }
    }
  }
#endif
