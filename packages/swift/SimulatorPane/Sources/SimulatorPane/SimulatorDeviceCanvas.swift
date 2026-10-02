import CodevisorClient
import ScreenSharing
import SwiftUI

/// The device as it's held: its bezel and hardware buttons turned with it, the live screen
/// upright inside, all scaled to fit the pane.
struct SimulatorDeviceCanvas: View {
  let model: SimulatorPaneModel
  let device: ServerSimulatorDevice
  /// Room between the device and the pane's edges; the action bar brings its own spacing below.
  static let margin: CGFloat = 16
  static let bottomMargin: CGFloat = 4
  #if os(macOS)
    /// The window toolbar's height: it floats over a pane that starts at the window's top.
    static let minimumTop: CGFloat = 52
  #else
    static let minimumTop: CGFloat = 0
  #endif

  @Environment(\.displayScale) private var displayScale
  @State private var bezel: CGImage?
  @State private var mask: CGImage?
  /// The angle the device is drawn at. It keeps counting past a full turn, so each turn animates
  /// the short way (portrait to landscape left is -90°, not +270°).
  @State private var angle: Double?

  private var orientation: ScreenSharingSimulatorOrientation { model.deviceState?.orientation ?? .portrait }

  /// The screen in points, in its native orientation.
  private var screenPoints: CGSize {
    guard let display = model.display, display.scale > 0 else {
      return device.deviceType.productFamily == "Apple TV"
        ? CGSize(width: 960, height: 540) : CGSize(width: 402, height: 874)
    }
    return CGSize(width: display.width / display.scale, height: display.height / display.scale)
  }

  private var layout: SimulatorChromeLayout {
    if let chrome = model.chrome { return chrome.layout(screen: screenPoints) }
    return .bare(screen: screenPoints, cornerRadius: model.display?.cornerRadii.max() ?? 0)
  }

  var body: some View {
    GeometryReader { proxy in
      let layout = layout
      let turns = orientation.quarterTurns
      let rotated = turns % 2 == 0 ? layout.canvas : CGSize(width: layout.canvas.height, height: layout.canvas.width)
      // The reader already fills only the safe area (below the toolbar, above the action bar);
      // clear the toolbar ourselves only where the pane still runs under it.
      let underToolbar = max(0, Self.minimumTop - proxy.frame(in: .global).minY)
      let reserved = EdgeInsets(
        top: underToolbar + Self.margin, leading: Self.margin, bottom: Self.bottomMargin, trailing: Self.margin)
      let available = CGSize(
        width: max(1, proxy.size.width - reserved.leading - reserved.trailing),
        height: max(1, proxy.size.height - reserved.top - reserved.bottom))
      let scale = min(available.width / rotated.width, available.height / rotated.height, 1.5)
      // The device is laid out at the larger of its upright and sideways fits and shrunk to the
      // current one with a transform. A turn then changes only transforms, which move bezel and
      // live video together; a changing layout size would tween the bezel while the video's
      // platform view jumped straight to its new size, leaving black gaps mid-turn.
      let drawn = max(
        min(available.width / layout.canvas.width, available.height / layout.canvas.height, 1.5),
        min(available.width / layout.canvas.height, available.height / layout.canvas.width, 1.5))
      let screen = Self.rotate(layout.screen, in: layout.canvas, quarterTurns: turns)
      let origin = CGPoint(
        x: reserved.leading + (available.width - rotated.width * scale) / 2,
        y: reserved.top + (available.height - rotated.height * scale) / 2)
      ZStack(alignment: .topLeading) {
        // Frame and screen turn together, like glass in a real device; the video arrives the
        // device's way up and iOS rotates its own interface inside it.
        device(layout: layout, scale: drawn)
          .frame(width: layout.canvas.width * drawn, height: layout.canvas.height * drawn)
          .scaleEffect(scale / drawn)
          .rotationEffect(.degrees(angle ?? orientation.degrees))
          .animation(.smooth(duration: 0.35), value: angle)
          .frame(width: rotated.width * scale, height: rotated.height * scale)
          .offset(x: origin.x, y: origin.y)
          .animation(.smooth(duration: 0.35), value: orientation)
        // Touches are taken upright, as the viewer sees the screen; the host maps them back.
        screenInput
          .frame(width: screen.width * scale, height: screen.height * scale)
          .offset(x: origin.x + screen.minX * scale, y: origin.y + screen.minY * scale)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .onChange(of: orientation) { old, new in
        angle = (angle ?? old.degrees) + Self.shortestTurn(from: old.degrees, to: new.degrees)
      }
      // Another device starts from its own orientation, without spinning into it.
      .onChange(of: device.udid) { angle = nil }
      .task(
        id: ArtworkKey(
          chrome: model.chrome?.definition.identifier, screen: screenPoints,
          scale: (drawn * displayScale * 4).rounded() / 4)
      ) {
        let chrome = model.chrome
        let pixelScale = drawn * displayScale
        bezel = await Task.detached(priority: .userInitiated) {
          chrome.flatMap { SimulatorArtwork.bezel(chrome: $0, layout: layout, scale: pixelScale) }
        }.value
      }
      .task(
        id: MaskKey(display: model.display?.name, width: (layout.screen.width * drawn * displayScale).rounded())
      ) {
        guard let display = model.display else { mask = nil; return }
        let native = layout.screen.size
        let pixels = CGSize(width: native.width * drawn * displayScale, height: native.height * drawn * displayScale)
        mask = await Task.detached(priority: .userInitiated) {
          SimulatorArtwork.mask(display: display, pixels: pixels, quarterTurns: 0)
        }.value
      }
    }
  }

  private struct ArtworkKey: Equatable {
    var chrome: String?
    var screen: CGSize
    var scale: CGFloat
  }

  private struct MaskKey: Equatable {
    var display: String?
    var width: CGFloat
  }

  /// The device as it's made, upright: its frame, hardware buttons and screen.
  private func device(layout: SimulatorChromeLayout, scale: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      chrome(layout: layout, scale: scale)
      screen
        .frame(width: layout.screen.width * scale, height: layout.screen.height * scale)
        .offset(x: layout.screen.minX * scale, y: layout.screen.minY * scale)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.35), radius: 24 * scale, y: 10 * scale)
  }

  @ViewBuilder private func chrome(layout: SimulatorChromeLayout, scale: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(layout.buttons.filter { $0.input.onTop != true }) { button in
        SimulatorHardwareButton(button: button, chrome: model.chrome, scale: scale) { down in
          model.send(.button(name: button.input.name, down: down))
        }
      }
      if let bezel {
        Image(decorative: bezel, scale: 1)
          .resizable()
          .interpolation(.high)
          .allowsHitTesting(false)
      } else {
        RoundedRectangle(cornerRadius: layout.outerCornerRadius * scale, style: .continuous)
          .fill(Color(white: 0.08))
          .overlay(
            RoundedRectangle(cornerRadius: layout.outerCornerRadius * scale, style: .continuous)
              .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
          )
          .frame(width: layout.frame.width * scale, height: layout.frame.height * scale)
          .offset(x: layout.frame.minX * scale, y: layout.frame.minY * scale)
          .allowsHitTesting(false)
      }
      ForEach(layout.buttons.filter { $0.input.onTop == true }) { button in
        SimulatorHardwareButton(button: button, chrome: model.chrome, scale: scale) { down in
          model.send(.button(name: button.input.name, down: down))
        }
      }
    }
    .frame(width: layout.canvas.width * scale, height: layout.canvas.height * scale, alignment: .topLeading)
  }

  /// The video, the device's way up, in the screen's shape.
  private var screen: some View {
    ZStack {
      Color.black
      if let source = model.connection?.source {
        SimulatorScreenView(source: source, mask: mask, input: input)
      }
    }
    .mask {
      if let mask { Image(decorative: mask, scale: 1).resizable() } else { Rectangle() }
    }
  }

  /// Over the screen, upright: where touches land, and what the stream is doing until it shows.
  @ViewBuilder private var screenInput: some View {
    ZStack {
      SimulatorScreenView(source: nil, mask: nil, input: input)
      switch model.connection?.phase {
      case .failed(let message):
        VStack(spacing: 10) {
          Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
          Button("Reconnect") { model.reconnect() }
            .buttonStyle(.glass)
        }
        .padding(20)
      case .streaming:
        EmptyView()
      default:
        ProgressView().controlSize(.regular).tint(.white).allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(device.name) screen")
  }

  private var input: SimulatorScreenInput {
    let model = model
    let family = device.deviceType.productFamily
    return SimulatorScreenInput(
      touch: { phase, touches in model.send(.touch(phase: phase, touches: touches)) },
      key: { usage, down in model.send(.key(usage: usage, down: down)) },
      scroll: { delta in if family == "Apple Watch" { model.send(.crown(delta: delta)) } },
      frame: { size in model.connection?.presented(frameSize: size) })
  }

  /// The signed turn, in degrees, from one angle to another the short way round (-180 to 180).
  static func shortestTurn(from old: Double, to new: Double) -> Double {
    (new - old + 540).truncatingRemainder(dividingBy: 360) - 180
  }

  /// `rect` inside a canvas of `size`, after turning the canvas clockwise by quarter turns.
  static func rotate(_ rect: CGRect, in size: CGSize, quarterTurns: Int) -> CGRect {
    switch ((quarterTurns % 4) + 4) % 4 {
    case 1: CGRect(x: size.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
    case 2: CGRect(x: size.width - rect.maxX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    case 3: CGRect(x: rect.minY, y: size.width - rect.maxX, width: rect.height, height: rect.width)
    default: rect
    }
  }
}

/// A hardware button on the bezel: press and hold sends down and up; hovering slides it out as
/// Simulator does.
struct SimulatorHardwareButton: View {
  let button: SimulatorChromeLayout.Button
  let chrome: SimulatorChrome?
  let scale: CGFloat
  let send: (Bool) -> Void

  @Environment(\.displayScale) private var displayScale
  @State private var pressed = false
  @State private var hovering = false

  var body: some View {
    let frame = hovering || pressed ? button.rolloverFrame : button.frame
    let name = pressed ? (button.input.imageDown ?? button.input.image) : button.input.image
    Group {
      if let name, let image = chrome?.images[name]?.render(size: button.frame.size, scale: scale * displayScale) {
        Image(decorative: image, scale: 1).resizable()
      } else {
        Capsule().fill(Color(white: 0.25))
      }
    }
    .frame(width: frame.width * scale, height: frame.height * scale)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !pressed else { return }
          pressed = true
          send(true)
        }
        .onEnded { _ in
          pressed = false
          send(false)
        }
    )
    .accessibilityElement()
    .accessibilityLabel(button.input.accessibilityTitle ?? button.input.name)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      send(true)
      Task {
        try? await Task.sleep(for: .milliseconds(100))
        send(false)
      }
    }
    .help(button.input.accessibilityTitle ?? button.input.name)
    // Placed by layout (not offset), so where it's drawn is also where it hovers and clicks.
    .position(x: frame.midX * scale, y: frame.midY * scale)
    .animation(.snappy(duration: 0.15), value: hovering || pressed)
  }
}
