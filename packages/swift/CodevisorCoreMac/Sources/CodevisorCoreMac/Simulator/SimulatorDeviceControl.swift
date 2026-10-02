@preconcurrency import Foundation
import CoreGraphics
import ScreenSharing
@preconcurrency import XPC

/// Input and device state for one booted simulator, shared by everyone viewing it: touches,
/// buttons and keys, how it's held, and (on a foldable) how far it's open. iOS 27 and later
/// take input through CoreDevice services in the guest; earlier runtimes through SimulatorKit.
@MainActor
final class SimulatorDeviceControl {
  let udid: String
  let family: String
  /// The foldable's postures, in order; empty for a device that doesn't fold.
  let postures: [String]
  private(set) var orientation: ScreenSharingSimulatorOrientation = .portrait
  private(set) var posture: String?
  private let device: NSObject
  /// Input goes through CoreDevice's services in the guest whenever the runtime offers them
  /// (current runtimes, iOS 26 included); SimulatorKit's legacy client is the fallback.
  private var modern: Bool
  private var digitizer: SimulatorRuntime.GuestService?
  private var orientationService: SimulatorRuntime.GuestService?
  private var vendorDefined: SimulatorRuntime.GuestService?
  private var legacy: SimulatorRuntime.LegacyHID?
  /// Fingers down, by viewer finger id, in framebuffer-normalized coordinates.
  private var fingers: [Int: CGPoint] = [:]
  private var fingerOrder: [Int] = []
  private var gestureEdge: UInt64 = 0
  private let queue = DispatchQueue(label: "codevisor.simulator.control", qos: .userInteractive)
  private var postureRamp: Task<Void, Never>?
  private var hingeAngle = 0
  var onChange: (() -> Void)?

  init(udid: String) throws {
    self.udid = udid
    device = try SimulatorRuntime.device(udid: udid)
    guard SimulatorRuntime.isBooted(device) else { throw SimulatorRuntime.Failure("Start the simulator first.") }
    family = SimulatorRuntime.productFamily(device)
    modern = true
    let integrated = SimulatorRuntime.displayCapabilities(device).values.filter {
      $0["displayType"] as? String == "integrated" && $0["hasDigitizer"] as? Bool == true
    }
    postures = integrated.count >= 2 ? ["closed", "book", "open"] : []
    if !postures.isEmpty { posture = "closed" }
    readOrientation()
  }

  /// Learns how the device is held now (another viewer, Simulator, or Device Hub may have turned
  /// it), so the first frames come out the right way up.
  private func readOrientation() {
    guard canRotate, let service = orientationServiceIfAvailable() else { return }
    let payload = Unchecked(xpc_dictionary_create(nil, nil, 0))
    xpc_dictionary_set_value(payload.value, "currentOrientation", xpc_dictionary_create(nil, nil, 0))
    queue.async { [weak self] in
      let reply = service.request("OrientationRequest", payload.value)
      guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
        let name = xpc_dictionary_get_string(reply, "currentDeviceOrientation").map({ String(cString: $0) }),
        let orientation = ScreenSharingSimulatorOrientation(rawValue: name)
      else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.orientation != orientation else { return }
          self.orientation = orientation
          self.onChange?()
        }
      }
    }
  }

  var canRotate: Bool { family == "iPhone" || family == "iPad" }

  var state: ScreenSharingSimulatorState {
    .init(
      orientation: orientation, posture: posture, postures: postures, display: displayName, canRotate: canRotate)
  }

  /// The screen to stream: a closed foldable shows its cover, an open one its inner screen.
  var displayName: String {
    guard !postures.isEmpty, let posture, posture != "closed" else { return "primary" }
    return "primary-1"
  }

  // MARK: Touch

  /// Touches in framebuffer-normalized coordinates of the streamed screen. DTUHID carries at
  /// most two fingers per event; a finger joining or leaving starts a fresh gesture.
  func touch(_ phase: ScreenSharingSimulatorTouchPhase, _ touches: [(id: Int, point: CGPoint, edge: UInt64)]) {
    let before = fingerOrder.prefix(2)
    switch phase {
    case .began:
      for touch in touches {
        if fingers[touch.id] == nil { fingerOrder.append(touch.id) }
        fingers[touch.id] = touch.point
        if fingerOrder.count == 1 { gestureEdge = touch.edge }
      }
    case .moved:
      for touch in touches where fingers[touch.id] != nil { fingers[touch.id] = touch.point }
    case .ended, .cancelled:
      for touch in touches where fingers[touch.id] != nil { fingers[touch.id] = touch.point }
    }
    let active = Array(fingerOrder.prefix(2))
    if phase == .ended || phase == .cancelled {
      // Lift the whole gesture where its fingers last were, then carry on with who's left.
      if !active.isEmpty { sendDigitizer(phase: 2, ids: active) }
      for touch in touches {
        fingers[touch.id] = nil
        fingerOrder.removeAll { $0 == touch.id }
      }
      let remaining = Array(fingerOrder.prefix(2))
      if !remaining.isEmpty { sendDigitizer(phase: 0, ids: remaining) } else { gestureEdge = 0 }
      return
    }
    if phase == .began, !before.isEmpty, Array(before) != active {
      sendDigitizer(phase: 2, ids: Array(before))
    }
    sendDigitizer(phase: phase == .began && Array(before) != active ? 0 : 1, ids: active)
  }

  /// eventType 0 begins, 1 moves, 2 ends.
  private func sendDigitizer(phase: UInt64, ids: [Int]) {
    guard let first = ids.first.flatMap({ fingers[$0] }) else { return }
    let second = ids.count > 1 ? fingers[ids[1]] : nil
    let edge = second == nil ? gestureEdge : 0
    if modern, let service = digitizerService() {
      let payload = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_value(payload, "pointOne", Self.point(first))
      if let second { xpc_dictionary_set_value(payload, "pointTwo", Self.point(second)) }
      xpc_dictionary_set_uint64(payload, "eventType", phase)
      xpc_dictionary_set_uint64(payload, "edge", edge)
      xpc_dictionary_set_uint64(payload, "target", 0)
      service.send("IndigoDigitizerEvent", payload)
    } else if let legacy = legacyHID() {
      legacy.touch(first, second, down: phase != 2, edge: UInt32(edge))
    }
  }

  private static func point(_ point: CGPoint) -> xpc_object_t {
    let value = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_double(value, "x", Double(point.x))
    xpc_dictionary_set_double(value, "y", Double(point.y))
    return value
  }

  // MARK: Buttons and keys

  /// Hardware buttons by chrome name, as (usage page, usage).
  static let buttons: [String: (page: UInt32, usage: UInt32)] = [
    "home": (0x0C, 0x40), "power": (0x0C, 0x30), "lock": (0x0C, 0x30), "siri": (0x0C, 0xCF),
    "volume-up": (0x0C, 0xE9), "volume-down": (0x0C, 0xEA), "action": (0x0B, 0x2D), "mute": (0x0B, 0x2E),
    "play-pause": (0x0C, 0xCD), "digital-crown": (0x0C, 0x40), "side-button": (0x0C, 0x95),
    "left-side-button": (0x0B, 0x2D), "menu": (0x0C, 0x86),
  ]

  /// A named button, or `hid:<page>:<usage>` straight from the chrome.
  func button(_ name: String, down: Bool) {
    let usage: (page: UInt32, usage: UInt32)?
    if name.hasPrefix("hid:") {
      let parts = name.split(separator: ":").compactMap { UInt32($0) }
      usage = parts.count == 2 ? (parts[0], parts[1]) : nil
    } else if name == "menu", family == "Apple TV" {
      // The remote's Back/Menu is Escape on a TV's keyboard.
      key(0x29, down: down)
      return
    } else {
      usage = Self.buttons[name]
    }
    guard let usage else { return }
    if modern, let service = digitizerService() {
      let payload = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_uint64(payload, "usagePage", UInt64(usage.page))
      xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage.usage))
      xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
      service.send("IndigoButtonEvent", payload)
    } else if let legacy = legacyHID() {
      legacy.button(page: usage.page, usage: usage.usage, down: down)
    }
  }

  func key(_ usage: Int, down: Bool) {
    guard (0...0xFFFF).contains(usage) else { return }
    if modern, let service = digitizerService() {
      let payload = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
      xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
      service.send("IndigoKeyboardButtonEvent", payload)
    } else if let legacy = legacyHID() {
      legacy.key(UInt32(usage), down: down)
    }
  }

  // MARK: Orientation and posture

  func rotate(to orientation: ScreenSharingSimulatorOrientation) {
    guard canRotate, orientation != self.orientation else { return }
    self.orientation = orientation
    onChange?()
    // Device Hub's own rotation: CoreMotion's device orientation, through the guest's
    // vendor-defined HID event, so apps see the device turn; plus CoreDevice's orientation
    // service, which sets the interface orientation directly.
    let viaMotion = sendDeviceState(
      source: "orientation-picker-control", type: "enum", value: Self.motionName(orientation))
    if let service = orientationServiceIfAvailable() {
      let payload = xpc_dictionary_create(nil, nil, 0)
      let change = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_string(change, "_0", orientation.rawValue)
      xpc_dictionary_set_value(payload, "changeOrientation", change)
      let request = Unchecked(payload)
      // The service replies; wait for it off the main thread.
      queue.async { _ = service.request("OrientationRequest", request.value) }
    } else if !viaMotion {
      // A runtime without CoreDevice's services.
      SimulatorRuntime.sendOrientationEvent(device: device, value: Self.gsEventValue(orientation))
    }
  }

  /// locationd's names for CoreMotion orientations (it rejects UIKit's camel case).
  nonisolated static func motionName(_ orientation: ScreenSharingSimulatorOrientation) -> String {
    switch orientation {
    case .portrait: "portrait"
    case .portraitUpsideDown: "pud"
    case .landscapeLeft: "landscape-left"
    case .landscapeRight: "landscape-right"
    }
  }

  nonisolated static func gsEventValue(_ orientation: ScreenSharingSimulatorOrientation) -> UInt32 {
    switch orientation {
    case .portrait: 1
    case .portraitUpsideDown: 2
    case .landscapeRight: 3
    case .landscapeLeft: 4
    }
  }

  /// Hinge angles Device Hub uses for each posture.
  nonisolated static func hingeAngle(_ posture: String) -> Int? {
    switch posture {
    case "closed": 0
    case "book": 130
    case "open": 180
    default: nil
    }
  }

  /// Folds or unfolds by easing the hinge toward the posture's angle, as a hand would; the guest
  /// swaps screens as it passes its thresholds.
  func setPosture(_ posture: String) {
    guard postures.contains(posture), let target = Self.hingeAngle(posture) else { return }
    self.posture = posture
    onChange?()
    postureRamp?.cancel()
    postureRamp = Task { [weak self] in
      guard let self else { return }
      let start = self.hingeAngle
      let steps = 15
      for step in 1...steps {
        guard !Task.isCancelled else { return }
        let progress = Double(step) / Double(steps)
        let eased = 1 - pow(1 - progress, 3)
        // The guest's plist parser takes whole degrees only.
        self.hingeAngle = start + Int((Double(target - start) * eased).rounded())
        self.sendDeviceState(source: "hinge-slider-control", type: "range", value: self.hingeAngle)
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
  }

  /// CoreMotion state the guest's locationd relays: an XML plist on HID usage page 0xFF61,
  /// usage 0x5B. Values are integers or strings; the guest's parser rejects reals.
  @discardableResult
  private func sendDeviceState(source: String, type: String, value: Any) -> Bool {
    guard let service = vendorDefinedService() else { return false }
    let state: [String: Any] = ["source": source, "type": type, "value": value]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0) else {
      return false
    }
    let payload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(payload, "usagePage", 0xFF61)
    xpc_dictionary_set_uint64(payload, "usage", 0x5B)
    xpc_dictionary_set_uint64(payload, "version", 0)
    data.withUnsafeBytes { bytes in
      if let base = bytes.baseAddress { xpc_dictionary_set_data(payload, "data", base, data.count) }
    }
    service.send("IndigoVendorDefinedEvent", payload)
    return true
  }

  // MARK: Connections

  private func digitizerService() -> SimulatorRuntime.GuestService? {
    if digitizer == nil {
      digitizer = try? SimulatorRuntime.GuestService(
        device: device, feature: "com.apple.coredevice.feature.remote.hid.digitizer")
      // An older runtime without CoreDevice's services: use SimulatorKit from now on.
      if digitizer == nil { modern = false }
    }
    return digitizer
  }

  private func orientationServiceIfAvailable() -> SimulatorRuntime.GuestService? {
    if orientationService == nil {
      orientationService = try? SimulatorRuntime.GuestService(
        device: device, feature: "com.apple.coredevice.feature.remote.devicecontrol.orientation")
    }
    return orientationService
  }

  private func vendorDefinedService() -> SimulatorRuntime.GuestService? {
    if vendorDefined == nil {
      vendorDefined = try? SimulatorRuntime.GuestService(
        device: device, feature: "com.apple.coredevice.feature.remote.hid.vendordefined")
    }
    return vendorDefined
  }

  private func legacyHID() -> SimulatorRuntime.LegacyHID? {
    if legacy == nil { legacy = try? SimulatorRuntime.LegacyHID(device: device) }
    return legacy
  }

  /// Lets go of every finger (a viewer left mid-gesture).
  func releaseTouches() {
    let active = Array(fingerOrder.prefix(2))
    if !active.isEmpty { sendDigitizer(phase: 2, ids: active) }
    fingers.removeAll()
    fingerOrder.removeAll()
    gestureEdge = 0
  }

  func close() {
    releaseTouches()
    postureRamp?.cancel()
    // Let queued events drain before the guest's virtual devices go away with the connections.
    let retained = Unchecked((digitizer, orientationService, vendorDefined, legacy))
    queue.asyncAfter(deadline: .now() + 1) { _ = retained }
    digitizer = nil
    orientationService = nil
    vendorDefined = nil
    self.legacy = nil
  }
}

/// Carries a value the compiler can't prove sendable (XPC objects, framework objects) to the
/// one queue that uses it next.
struct Unchecked<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
