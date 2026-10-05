import CodevisorClient
import ScreenSharing
import SwiftUI

/// The device as it's held: its bezel and hardware buttons turned with it, the live screen
/// upright inside, all scaled to fit the pane. A foldable is drawn at one size whichever screen
/// shows, bends open as a book, and folds shut and open as Device Hub animates it.
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
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  /// Each screen's bezel and screen mask, by face, at the scale the device is drawn.
  @State private var bezels: [String: CGImage] = [:]
  @State private var masks: [String: CGImage] = [:]
  /// The angle the device is drawn at as it's held. It keeps counting past a full turn, so each
  /// turn animates the short way (portrait to landscape left is -90°, not +270°).
  @State private var angle: Double?
  @State private var feed = SimulatorScreenFeed()
  /// A foldable's hinge as drawn, in degrees open; it eases to each new posture.
  @State private var hinge: Double?
  /// Folding between screens: drawn from a still of the screen it left until the hinge settles.
  @State private var fold: Fold?

  private struct Fold {
    let id = UUID()
    /// The screen shown before, and what it showed.
    let from: String
    let snapshot: CGImage?
  }

  /// One of the device's screens laid out in its chrome, and how it's mounted in the device.
  struct Face {
    let id: String
    let display: ServerSimulatorDisplay?
    let chrome: SimulatorChrome?
    let layout: SimulatorChromeLayout
    /// Clockwise quarter turns from the screen as it's made to the device held upright.
    let mount: Int

    /// The device around this screen, upright in the hand.
    var presented: CGSize {
      mount % 2 == 0 ? layout.canvas : CGSize(width: layout.canvas.height, height: layout.canvas.width)
    }
    var screen: CGRect { SimulatorDeviceCanvas.rotate(layout.screen, in: layout.canvas, quarterTurns: mount) }
    var bezel: CGRect { SimulatorDeviceCanvas.rotate(layout.frame, in: layout.canvas, quarterTurns: mount) }
  }

  private var state: ScreenSharingSimulatorState? { model.deviceState }

  private var fitsCurrentScreen: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }
  private var held: Int { state?.orientation.quarterTurns ?? 0 }
  private var heldDegrees: Double { Double(held) * 90 }

  private func face(_ display: ServerSimulatorDisplay?, mount: Int) -> Face {
    let points: CGSize
    if let display, display.scale > 0 {
      points = CGSize(width: display.width / display.scale, height: display.height / display.scale)
    } else {
      points =
        device.deviceType.productFamily == "Apple TV"
        ? CGSize(width: 960, height: 540) : CGSize(width: 402, height: 874)
    }
    let chrome = (display?.chromeIdentifier ?? model.deviceType?.chromeIdentifier).flatMap { model.chromes[$0] }
    let layout =
      chrome?.layout(screen: points) ?? .bare(screen: points, cornerRadius: display?.cornerRadii.max() ?? 0)
    return Face(id: display?.name ?? "screen", display: display, chrome: chrome, layout: layout, mount: mount)
  }

  /// The screen the stream shows.
  private var current: Face { face(model.display, mount: state?.screenTurns ?? 0) }

  /// A foldable's cover screen (shown closed) and inner screen (open and as a book).
  private var foldable: (cover: Face, inner: Face)? {
    guard let state, !state.postures.isEmpty, let displays = model.deviceType?.displays else { return nil }
    let touchscreens = displays.filter(\.hasDigitizer)
    guard let cover = touchscreens.first(where: { $0.name == "primary" }),
      let inner = touchscreens.first(where: { $0.name != "primary" })
    else { return nil }
    let mountings = state.mountings ?? [:]
    return (face(cover, mount: mountings[cover.name] ?? 0), face(inner, mount: mountings[inner.name] ?? 0))
  }

  var body: some View {
    GeometryReader { proxy in
      let current = current
      let foldable = foldable
      // A foldable keeps one size, the larger of its screens', so folding doesn't resize it.
      let box =
        foldable.map {
          CGSize(
            width: max($0.cover.presented.width, $0.inner.presented.width),
            height: max($0.cover.presented.height, $0.inner.presented.height))
        } ?? current.presented
      let held = held
      let rotated = held % 2 == 0 ? box : CGSize(width: box.height, height: box.width)
      // A narrow iPhone pane fits the screen that's showing, zooming as the device folds; with
      // room, the device keeps one size, as Device Hub draws it.
      let fit = fitsCurrentScreen ? current.presented : box
      let fitted = held % 2 == 0 ? fit : CGSize(width: fit.height, height: fit.width)
      // The reader already fills only the safe area (below the toolbar, above the action bar);
      // clear the toolbar ourselves only where the pane still runs under it.
      let underToolbar = max(0, Self.minimumTop - proxy.frame(in: .global).minY)
      let reserved = EdgeInsets(
        top: underToolbar + Self.margin, leading: Self.margin, bottom: Self.bottomMargin, trailing: Self.margin)
      let available = CGSize(
        width: max(1, proxy.size.width - reserved.leading - reserved.trailing),
        height: max(1, proxy.size.height - reserved.top - reserved.bottom))
      let scale = min(available.width / fitted.width, available.height / fitted.height, 1.5)
      // The device is laid out at the larger of its upright and sideways fits and shrunk to the
      // current one with a transform. A turn then changes only transforms, which move bezel and
      // live video together; a changing layout size would tween the bezel while the video's
      // platform view jumped straight to its new size, leaving black gaps mid-turn.
      let drawn =
        (foldable.map { [$0.cover.presented, $0.inner.presented] } ?? [box]).map { size in
          max(
            min(available.width / size.width, available.height / size.height, 1.5),
            min(available.width / size.height, available.height / size.width, 1.5))
        }.max() ?? 1
      let inBox = current.screen.offsetBy(
        dx: (box.width - current.presented.width) / 2, dy: (box.height - current.presented.height) / 2)
      let screen = Self.rotate(inBox, in: box, quarterTurns: held)
      let origin = CGPoint(
        x: reserved.leading + (available.width - rotated.width * scale) / 2,
        y: reserved.top + (available.height - rotated.height * scale) / 2)
      let faces = foldable.map { [$0.cover, $0.inner] } ?? [current]
      ZStack(alignment: .topLeading) {
        // Frame and screen turn together, like glass in a real device; iOS rotates its own
        // interface inside it.
        content(current: current, foldable: foldable, scale: drawn)
          .frame(width: box.width * drawn, height: box.height * drawn)
          .scaleEffect(scale / drawn)
          .animation(.timingCurve(0.45, 0, 0.2, 1, duration: 0.75), value: current.id)
          .rotationEffect(.degrees(angle ?? heldDegrees))
          .animation(.smooth(duration: 0.35), value: angle)
          .frame(width: rotated.width * scale, height: rotated.height * scale)
          .offset(x: origin.x, y: origin.y)
          .animation(.smooth(duration: 0.35), value: heldDegrees)
        // Touches are taken upright, as the viewer sees the screen; the host maps them back.
        screenInput(bend: bend(current: current, foldable: foldable))
          .frame(width: screen.width * scale, height: screen.height * scale)
          .offset(x: origin.x + screen.minX * scale, y: origin.y + screen.minY * scale)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .onChange(of: heldDegrees) { old, new in
        angle = (angle ?? old) + Self.shortestTurn(from: old, to: new)
      }
      // Another device starts from its own orientation and posture, without moving into them.
      .onChange(of: device.udid) {
        angle = nil
        hinge = nil
        fold = nil
      }
      .onChange(of: PostureKey(posture: state?.posture, display: state?.display), initial: true) { old, new in
        postureChanged(from: old, to: new)
      }
      .task(
        id: ArtworkKey(
          faces: faces.map { "\($0.id) \($0.chrome?.definition.identifier ?? "") \($0.layout.canvas)" },
          scale: (drawn * displayScale * 4).rounded() / 4)
      ) {
        let jobs = faces.map { (id: $0.id, chrome: $0.chrome, layout: $0.layout, display: $0.display) }
        let pixelScale = drawn * displayScale
        let artwork = await Task.detached(priority: .userInitiated) {
          var bezels: [String: CGImage] = [:]
          var masks: [String: CGImage] = [:]
          for job in jobs {
            bezels[job.id] = job.chrome.flatMap {
              SimulatorArtwork.bezel(chrome: $0, layout: job.layout, scale: pixelScale)
            }
            let pixels = CGSize(
              width: job.layout.screen.width * pixelScale, height: job.layout.screen.height * pixelScale)
            masks[job.id] = job.display.flatMap { SimulatorArtwork.mask(display: $0, pixels: pixels, quarterTurns: 0) }
          }
          return (bezels, masks)
        }.value
        bezels = artwork.0
        masks = artwork.1
      }
    }
  }

  private struct ArtworkKey: Equatable {
    var faces: [String]
    var scale: CGFloat
  }

  private struct PostureKey: Equatable {
    var posture: String?
    var display: String?
  }

  // MARK: Folding

  /// Device Hub's hinge for each posture, in degrees open.
  nonisolated static func hingeAngle(_ posture: String?) -> Double? {
    switch posture {
    case "closed": 0
    case "book": 130
    case "open": 180
    default: nil
    }
  }

  /// Eases the hinge to the new posture. Swapping screens folds over a still of the one left
  /// (the guest blanks and wakes the other meanwhile), then hands back to the live stream.
  private func postureChanged(from old: PostureKey, to new: PostureKey) {
    guard let target = Self.hingeAngle(new.posture) else {
      hinge = nil
      fold = nil
      return
    }
    guard hinge != nil, old.posture != nil else {
      hinge = target
      return
    }
    var duration = 0.45
    if let from = old.display, old.display != new.display {
      fold = Fold(from: from, snapshot: snapshot(of: from))
      duration = 0.75
    }
    let id = fold?.id
    withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: duration)) {
      hinge = target
    } completion: {
      if fold?.id == id { fold = nil }
    }
  }

  /// The stream's last frame, if it's the shape of `display` (and not already the next screen).
  private func snapshot(of display: String) -> CGImage? {
    guard let image = feed.snapshot(),
      let screen = model.deviceType?.displays.first(where: { $0.name == display }), screen.height > 0, image.height > 0
    else { return nil }
    let ratio = (Double(image.width) / Double(image.height)) / (screen.width / screen.height)
    return abs(ratio - 1) < 0.01 ? image : nil
  }

  /// A book's halves tilt toward you; touches on them are mapped back to the flat screen.
  private struct Bend {
    var hinge: Double
    var center: CGPoint
    var depth: CGFloat
    var screen: CGRect
    var held: Int
  }

  private func bend(current: Face, foldable: (cover: Face, inner: Face)?) -> Bend? {
    guard let foldable, current.id == foldable.inner.id, fold == nil, let hinge, hinge < 180 else { return nil }
    let inner = foldable.inner
    return Bend(
      hinge: hinge, center: CGPoint(x: inner.bezel.midX, y: inner.presented.height / 2),
      depth: SimulatorFold.depth(width: inner.presented.width), screen: inner.screen,
      held: held)
  }

  // MARK: Drawing

  @ViewBuilder private func content(current: Face, foldable: (cover: Face, inner: Face)?, scale: CGFloat) -> some View {
    let halves = foldable != nil && hinge != nil && (fold != nil || current.id == foldable?.inner.id)
    let sources = feed.sources(
      for: model.connection?.source, arrangement: fold != nil ? "fold" : halves ? "halves" : "screen \(current.id)")
    if let foldable, let hinge, halves {
      let inner = foldable.inner, cover = foldable.cover
      SimulatorFoldScene(
        hinge: hinge,
        size: CGSize(width: inner.presented.width * scale, height: inner.presented.height * scale),
        hingeX: inner.bezel.midX * scale,
        coverSize: CGSize(width: cover.presented.width * scale, height: cover.presented.height * scale),
        coverHingeX: cover.bezel.minX * scale,
        shadowRadius: 24 * scale,
        inner: { half in
          if let fold {
            still(inner, image: fold.from == inner.id ? fold.snapshot : nil, scale: scale)
          } else {
            live(inner, source: sources.indices.contains(half) ? sources[half] : nil, scale: scale, half: half)
          }
        },
        cover: {
          still(cover, image: fold?.from == cover.id ? fold?.snapshot : nil, scale: scale)
        })
    } else {
      live(current, source: sources.first ?? nil, scale: scale)
        .shadow(color: .black.opacity(0.35), radius: 24 * scale, y: 10 * scale)
    }
  }

  /// A screen's device, its buttons pressable and its screen live, turned as it's mounted. Drawn
  /// as one `half` of a foldable, it keeps only the buttons on that side of the hinge.
  private func live(_ face: Face, source: SimulatorScreenSource?, scale: CGFloat, half: Int? = nil) -> some View {
    mounted(face, scale: scale) {
      chrome(face, scale: scale, interactive: true) { button in
        guard let half else { return true }
        let center = Self.rotate(button.frame, in: face.layout.canvas, quarterTurns: face.mount).midX
        return (center < face.bezel.midX) == (half == 0)
      }
      screenShape(face) {
        if let source { SimulatorScreenView(source: source, mask: masks[face.id], input: input(bend: nil)) }
      }
      .frame(width: face.layout.screen.width * scale, height: face.layout.screen.height * scale)
      .offset(x: face.layout.screen.minX * scale, y: face.layout.screen.minY * scale)
      .allowsHitTesting(false)
    }
  }

  /// A screen's device showing a still (or a dark screen), for folding.
  private func still(_ face: Face, image: CGImage?, scale: CGFloat) -> some View {
    mounted(face, scale: scale) {
      chrome(face, scale: scale, interactive: false) { _ in true }
      screenShape(face) {
        if let image { Image(decorative: image, scale: 1).resizable() }
      }
      .frame(width: face.layout.screen.width * scale, height: face.layout.screen.height * scale)
      .offset(x: face.layout.screen.minX * scale, y: face.layout.screen.minY * scale)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The device as it's made, then turned as the screen is mounted, filling `presented`.
  private func mounted<Content: View>(
    _ face: Face, scale: CGFloat, @ViewBuilder content: () -> Content
  ) -> some View {
    ZStack(alignment: .topLeading) { content() }
      .frame(width: face.layout.canvas.width * scale, height: face.layout.canvas.height * scale, alignment: .topLeading)
      .rotationEffect(.degrees(Double(face.mount) * 90))
      .frame(width: face.presented.width * scale, height: face.presented.height * scale)
  }

  /// The screen's glass: black under whatever it shows, in the screen's shape.
  private func screenShape<Content: View>(_ face: Face, @ViewBuilder content: () -> Content) -> some View {
    ZStack {
      Color.black
      content()
    }
    .mask {
      if let mask = masks[face.id] { Image(decorative: mask, scale: 1).resizable() } else { Rectangle() }
    }
  }

  @ViewBuilder private func chrome(
    _ face: Face, scale: CGFloat, interactive: Bool, showing: (SimulatorChromeLayout.Button) -> Bool
  ) -> some View {
    let layout = face.layout
    let buttons = layout.buttons.filter(showing)
    ZStack(alignment: .topLeading) {
      ForEach(buttons.filter { $0.input.onTop != true }) { button in
        hardwareButton(button, face: face, scale: scale)
      }
      if let bezel = bezels[face.id] {
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
      ForEach(buttons.filter { $0.input.onTop == true }) { button in
        hardwareButton(button, face: face, scale: scale)
      }
    }
    .frame(width: layout.canvas.width * scale, height: layout.canvas.height * scale, alignment: .topLeading)
    .allowsHitTesting(interactive)
  }

  private func hardwareButton(_ button: SimulatorChromeLayout.Button, face: Face, scale: CGFloat) -> some View {
    SimulatorHardwareButton(button: button, chrome: face.chrome, scale: scale) { down in
      model.send(.button(name: button.input.name, down: down))
    }
  }

  /// Over the screen, upright: where touches land, and what the stream is doing until it shows.
  @ViewBuilder private func screenInput(bend: Bend?) -> some View {
    ZStack {
      SimulatorScreenView(source: nil, mask: nil, input: input(bend: bend))
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

  private func input(bend: Bend?) -> SimulatorScreenInput {
    let model = model
    let family = device.deviceType.productFamily
    return SimulatorScreenInput(
      touch: { phase, touches in
        let touches = bend.map { bend in touches.map { Self.flatten($0, bend: bend) } } ?? touches
        model.send(.touch(phase: phase, touches: touches))
      },
      key: { usage, down in model.send(.key(usage: usage, down: down)) },
      scroll: { delta in if family == "Apple Watch" { model.send(.crown(delta: delta)) } },
      frame: { size in model.connection?.presented(frameSize: size) })
  }

  /// A touch on a book's tilted screen, where it lands on the flat one.
  private static func flatten(_ touch: ScreenSharingSimulatorTouch, bend: Bend) -> ScreenSharingSimulatorTouch {
    // Upright as seen, to the device as presented, then onto its flat screen and back.
    let point = unturn(CGPoint(x: touch.x, y: touch.y), turns: bend.held)
    let screen = bend.screen
    let drawn = CGPoint(x: screen.minX + point.x * screen.width, y: screen.minY + point.y * screen.height)
    let flat = SimulatorFold.flatten(
      drawn, hinge: bend.hinge, center: bend.center, depth: bend.depth)
    let normalized = CGPoint(
      x: min(1, max(0, (flat.x - screen.minX) / screen.width)),
      y: min(1, max(0, (flat.y - screen.minY) / screen.height)))
    let seen = unturn(normalized, turns: 4 - bend.held)
    return ScreenSharingSimulatorTouch(id: touch.id, x: seen.x, y: seen.y, edge: touch.edge)
  }

  /// A normalized point seen turned clockwise by `turns`, in the unturned picture.
  nonisolated static func unturn(_ point: CGPoint, turns: Int) -> CGPoint {
    switch ((turns % 4) + 4) % 4 {
    case 1: CGPoint(x: point.y, y: 1 - point.x)
    case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
    case 3: CGPoint(x: 1 - point.y, y: point.x)
    default: point
    }
  }

  /// The signed turn, in degrees, from one angle to another the short way round (-180 to 180).
  nonisolated static func shortestTurn(from old: Double, to new: Double) -> Double {
    (new - old + 540).truncatingRemainder(dividingBy: 360) - 180
  }

  /// `rect` inside a canvas of `size`, after turning the canvas clockwise by quarter turns.
  nonisolated static func rotate(_ rect: CGRect, in size: CGSize, quarterTurns: Int) -> CGRect {
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
    // Artwork drawn for the other kind of edge is drawn at its own size, then turned to lie along
    // this one.
    let art = button.turned ? CGSize(width: frame.height, height: frame.width) : frame.size
    Group {
      if let name,
        let image = chrome?.images[name]?.render(
          size: button.turned ? CGSize(width: button.frame.height, height: button.frame.width) : button.frame.size,
          scale: scale * displayScale)
      {
        Image(decorative: image, scale: 1).resizable()
      } else {
        Capsule().fill(Color(white: 0.25))
      }
    }
    .frame(width: art.width * scale, height: art.height * scale)
    .rotationEffect(.degrees(button.turned ? -90 : 0))
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
