import ScreenSharing
import SwiftUI

/// What the simulator's screen reports back: touches in framebuffer-normalized coordinates,
/// keys as HID usages, and the decoded video's size.
@MainActor
struct SimulatorScreenInput {
  var touch: (ScreenSharingSimulatorTouchPhase, [ScreenSharingSimulatorTouch]) -> Void
  var key: (_ usage: Int, _ down: Bool) -> Void
  /// Scroll-wheel travel, for a watch's Digital Crown.
  var scroll: (_ delta: Double) -> Void
  var frame: (CGSize) -> Void
}

/// The stream's video in a Metal view, clipped to the screen's mask, taking touches and keys.
/// Without a source it only takes input: a clear layer over a screen drawn elsewhere.
struct SimulatorScreenView {
  let source: SimulatorScreenSource?
  /// The screen's shape (rounded corners, cutouts) as an alpha mask; nil draws it square.
  let mask: CGImage?
  let input: SimulatorScreenInput

  /// Within this many points of an edge, a touch that starts there is a system edge gesture.
  static let edgeBand: CGFloat = 12

  static func normalized(_ point: CGPoint, in size: CGSize) -> (Double, Double) {
    guard size.width > 0, size.height > 0 else { return (0, 0) }
    return (
      Double(min(1, max(0, point.x / size.width))), Double(min(1, max(0, point.y / size.height)))
    )
  }

  static func edge(of point: CGPoint, in size: CGSize) -> ScreenSharingSimulatorEdge? {
    if point.y >= size.height - edgeBand { return .bottom }
    if point.y <= edgeBand { return .top }
    if point.x <= edgeBand { return .left }
    if point.x >= size.width - edgeBand { return .right }
    return nil
  }
}

#if os(macOS)
  import AppKit

  extension SimulatorScreenView: NSViewRepresentable {
    func makeNSView(context: Context) -> SimulatorScreenSurface {
      SimulatorScreenSurface(source: source)
    }

    func updateNSView(_ view: SimulatorScreenSurface, context: Context) {
      view.input = input
      view.setMask(mask)
      view.attach(source)
    }

    static func dismantleNSView(_ view: SimulatorScreenSurface, coordinator: ()) { view.stop() }
  }

  /// Mouse is one finger; Option adds a second, mirrored through the screen's center, for pinch
  /// and rotate as in Simulator. Keys go to the device while the screen has focus.
  final class SimulatorScreenSurface: NSView {
    var input: SimulatorScreenInput?
    private var metal: ScreenSharingMetalView?
    private weak var mailbox: ScreenSharingFrameMailbox?
    private let imageLayer = CALayer()
    private let maskLayer = CALayer()
    private var maskImage: CGImage?
    private var pinching = false
    private var pressedKeys = Set<Int>()

    init(source: SimulatorScreenSource?) {
      super.init(frame: .zero)
      wantsLayer = true
      layer?.backgroundColor = source == nil ? NSColor.clear.cgColor : NSColor.black.cgColor
      maskLayer.contentsGravity = .resize
      imageLayer.contentsGravity = .resize
      layer?.addSublayer(imageLayer)
      attach(source)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ source: SimulatorScreenSource?) {
      let mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics
      switch source {
      case nil:
        return
      case .image(let image):
        imageLayer.contents = image
        return
      case .video(let box, let values):
        mailbox = box
        metrics = values
      }
      guard mailbox !== self.mailbox else { return }
      metal?.stop()
      metal?.removeFromSuperview()
      self.mailbox = mailbox
      guard
        let metal = try? ScreenSharingMetalView(
          mailbox: mailbox, metrics: metrics, renderOnArrival: true, offMainPreparation: true)
      else { return }
      metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
      metal.frame = bounds
      metal.autoresizingMask = [.width, .height]
      metal.onFrameSize = { [weak self] size in self?.input?.frame(size) }
      addSubview(metal)
      self.metal = metal
    }

    func setMask(_ image: CGImage?) {
      guard image !== maskImage else { return }
      maskImage = image
      maskLayer.contents = image
      layer?.mask = image == nil ? nil : maskLayer
      needsLayout = true
    }

    func stop() {
      releaseKeys()
      metal?.stop()
    }

    override func layout() {
      super.layout()
      maskLayer.frame = bounds
      imageLayer.frame = bounds
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resignFirstResponder() -> Bool {
      releaseKeys()
      return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      pinching = event.modifierFlags.contains(.option)
      send(.began, event, edge: true)
    }

    override func mouseDragged(with event: NSEvent) { send(.moved, event, edge: false) }
    override func mouseUp(with event: NSEvent) { send(.ended, event, edge: false) }

    private func send(_ phase: ScreenSharingSimulatorTouchPhase, _ event: NSEvent, edge: Bool) {
      let point = convert(event.locationInWindow, from: nil)
      let (x, y) = SimulatorScreenView.normalized(point, in: bounds.size)
      var touches = [
        ScreenSharingSimulatorTouch(
          id: 0, x: x, y: y, edge: edge && !pinching ? SimulatorScreenView.edge(of: point, in: bounds.size) : nil)
      ]
      if pinching { touches.append(.init(id: 1, x: 1 - x, y: 1 - y)) }
      input?.touch(phase, touches)
    }

    override func scrollWheel(with event: NSEvent) {
      let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
      if delta != 0 { input?.scroll(delta) }
    }

    /// The key each Mac key went down as, so its key-up releases the same one.
    private var typedKeys: [UInt16: (usage: Int, shift: Bool)] = [:]

    override func keyDown(with event: NSEvent) {
      // ⌘-shortcuts stay with Codevisor (close tab, switch panes).
      guard !event.modifierFlags.contains(.command), let key = simulatorKey(for: event)
      else { return super.keyDown(with: event) }
      if event.isARepeat, typedKeys[event.keyCode] == nil { return }
      typedKeys[event.keyCode] = key
      // Shift for a shifted character typed without a Shift key held (synthesized text).
      let addShift =
        key.shift && !pressedKeys.contains(SimulatorKeyboard.leftShift)
        && !pressedKeys.contains(SimulatorKeyboard.rightShift)
      if addShift { input?.key(SimulatorKeyboard.leftShift, true) }
      input?.key(key.usage, true)
      if addShift {
        input?.key(key.usage, false)
        input?.key(SimulatorKeyboard.leftShift, false)
        typedKeys[event.keyCode] = nil
      }
    }

    override func keyUp(with event: NSEvent) {
      guard let key = typedKeys.removeValue(forKey: event.keyCode) else {
        if simulatorKey(for: event) == nil { super.keyUp(with: event) }
        return
      }
      input?.key(key.usage, false)
    }

    /// Printable characters by what they type; everything else (arrows, Return, F-keys) by key.
    private func simulatorKey(for event: NSEvent) -> (usage: Int, shift: Bool)? {
      if let characters = event.characters, characters.count == 1, let character = characters.first,
        !character.isNewline, character != "\t",
        character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }),
        let key = SimulatorKeyboard.key(for: character)
      {
        return key
      }
      return SimulatorKeyboard.usage(macKeyCode: event.keyCode).map { ($0, false) }
    }

    override func flagsChanged(with event: NSEvent) {
      guard let usage = SimulatorKeyboard.usage(macKeyCode: event.keyCode),
        SimulatorKeyboard.modifierUsages.contains(usage)
      else { return }
      let down = !pressedKeys.contains(usage)
      if down { pressedKeys.insert(usage) } else { pressedKeys.remove(usage) }
      input?.key(usage, down)
    }

    private func releaseKeys() {
      for usage in pressedKeys { input?.key(usage, false) }
      pressedKeys.removeAll()
      for key in typedKeys.values { input?.key(key.usage, false) }
      typedKeys.removeAll()
    }
  }
#else
  import UIKit

  extension SimulatorScreenView: UIViewRepresentable {
    func makeUIView(context: Context) -> SimulatorScreenSurface {
      SimulatorScreenSurface(source: source)
    }

    func updateUIView(_ view: SimulatorScreenSurface, context: Context) {
      view.input = input
      view.setMask(mask)
      view.attach(source)
    }

    static func dismantleUIView(_ view: SimulatorScreenSurface, coordinator: ()) { view.stop() }
  }

  /// Every finger is a finger on the device; a hardware keyboard types into it.
  final class SimulatorScreenSurface: UIView {
    var input: SimulatorScreenInput?
    private var metal: ScreenSharingMetalView?
    private weak var mailbox: ScreenSharingFrameMailbox?
    private let imageLayer = CALayer()
    private let maskLayer = CALayer()
    private var maskImage: CGImage?
    private var fingers: [ObjectIdentifier: Int] = [:]
    private var edges: [ObjectIdentifier: ScreenSharingSimulatorEdge] = [:]
    private var nextFinger = 0
    private var pressedKeys = Set<Int>()
    /// The navigation's back-swipes, switched off while a finger that started on the screen is down.
    private var heldGestures: [UIGestureRecognizer] = []

    init(source: SimulatorScreenSource?) {
      super.init(frame: .zero)
      backgroundColor = source == nil ? .clear : .black
      isMultipleTouchEnabled = true
      maskLayer.contentsGravity = .resize
      imageLayer.contentsGravity = .resize
      layer.addSublayer(imageLayer)
      attach(source)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ source: SimulatorScreenSource?) {
      let mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics
      switch source {
      case nil:
        return
      case .image(let image):
        imageLayer.contents = image
        return
      case .video(let box, let values):
        mailbox = box
        metrics = values
      }
      guard mailbox !== self.mailbox else { return }
      metal?.stop()
      metal?.removeFromSuperview()
      self.mailbox = mailbox
      guard let metal = try? ScreenSharingMetalView(mailbox: mailbox, metrics: metrics, renderOnArrival: true)
      else { return }
      metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
      metal.frame = bounds
      metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      metal.isUserInteractionEnabled = false
      metal.onFrameSize = { [weak self] size in self?.input?.frame(size) }
      addSubview(metal)
      self.metal = metal
    }

    func setMask(_ image: CGImage?) {
      guard image !== maskImage else { return }
      maskImage = image
      maskLayer.contents = image
      layer.mask = image == nil ? nil : maskLayer
      setNeedsLayout()
    }

    func stop() {
      releaseNavigationGestures()
      releaseKeys()
      metal?.stop()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      maskLayer.frame = bounds
      imageLayer.frame = bounds
    }

    override var canBecomeFirstResponder: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      becomeFirstResponder()
      holdNavigationGestures()
      for touch in touches {
        let key = ObjectIdentifier(touch)
        fingers[key] = nextFinger
        nextFinger += 1
        if let edge = SimulatorScreenView.edge(of: touch.location(in: self), in: bounds.size) { edges[key] = edge }
      }
      send(.began, touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(.moved, touches) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      send(.ended, touches)
      forget(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      send(.cancelled, touches)
      forget(touches)
    }

    private func send(_ phase: ScreenSharingSimulatorTouchPhase, _ touches: Set<UITouch>) {
      let mapped = touches.compactMap { touch -> ScreenSharingSimulatorTouch? in
        guard let id = fingers[ObjectIdentifier(touch)] else { return nil }
        let (x, y) = SimulatorScreenView.normalized(touch.location(in: self), in: bounds.size)
        return .init(id: id, x: x, y: y, edge: edges[ObjectIdentifier(touch)])
      }
      if !mapped.isEmpty { input?.touch(phase, mapped.sorted { $0.id < $1.id }) }
    }

    private func forget(_ touches: Set<UITouch>) {
      for touch in touches {
        fingers[ObjectIdentifier(touch)] = nil
        edges[ObjectIdentifier(touch)] = nil
      }
      if fingers.isEmpty {
        nextFinger = 0
        releaseNavigationGestures()
      }
    }

    /// A drag on the device belongs to the device: the navigation's back-swipes (from the edge, and
    /// from anywhere in the content) would otherwise take it as "go back". They're off only while
    /// a finger that started here is down, so swiping elsewhere still goes back.
    private func holdNavigationGestures() {
      guard heldGestures.isEmpty else { return }
      var responder: UIResponder? = next
      while let current = responder, !(current is UIViewController) { responder = current.next }
      guard let navigation = (responder as? UIViewController)?.navigationController else { return }
      heldGestures = [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer]
        .compactMap { $0 }
        .filter(\.isEnabled)
      for gesture in heldGestures { gesture.isEnabled = false }
    }

    private func releaseNavigationGestures() {
      for gesture in heldGestures { gesture.isEnabled = true }
      heldGestures.removeAll()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
      super.willMove(toWindow: newWindow)
      // Never leave the navigation without its back-swipes.
      if newWindow == nil { releaseNavigationGestures() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var unhandled = Set<UIPress>()
      for press in presses {
        guard let key = press.key, !key.modifierFlags.contains(.command) else {
          unhandled.insert(press)
          continue
        }
        let usage = key.keyCode.rawValue
        pressedKeys.insert(usage)
        input?.key(usage, true)
      }
      if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var unhandled = Set<UIPress>()
      for press in presses {
        guard let usage = press.key?.keyCode.rawValue, pressedKeys.remove(usage) != nil else {
          unhandled.insert(press)
          continue
        }
        input?.key(usage, false)
      }
      if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      pressesEnded(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
      releaseKeys()
      return super.resignFirstResponder()
    }

    private func releaseKeys() {
      for usage in pressedKeys { input?.key(usage, false) }
      pressedKeys.removeAll()
    }
  }
#endif
