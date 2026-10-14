@preconcurrency import Foundation
import CoreGraphics
import ScreenSharing
@preconcurrency import XPC

@MainActor
final class SimulatorDeviceControl {
  let udid: String
  let family: String
  let postures: [String]
  private let mountings: [String: Int]
  private(set) var orientation: ScreenSharingSimulatorOrientation = .portrait
  private(set) var posture: String?
  private let device: NSObject
  private var modern: Bool
  private var digitizer: SimulatorRuntime.GuestService?
  private var orientationService: SimulatorRuntime.GuestService?
  private var vendorDefined: SimulatorRuntime.GuestService?
  private var legacy: SimulatorRuntime.LegacyHID?
  private var fingers: [Int: CGPoint] = [:]
  private var fingerOrder: [Int] = []
  private var gestureEdge: UInt64 = 0
  private var touchTargets: [String: UInt64] = [:]
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
    mountings = SimulatorRuntime.screenTurns(device)
    readOrientation()
    _ = digitizerService()
    if !postures.isEmpty {
      posture = "closed"
      sendDeviceState(source: "hinge-slider-control", type: "range", value: .integer(0))
    }
  }

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
      orientation: orientation, posture: posture, postures: postures, display: displayName, canRotate: canRotate,
      screenTurns: screenTurns, mountings: postures.isEmpty ? nil : mountings)
  }

  var screenTurns: Int { mountings[displayName] ?? 0 }

  var displayName: String {
    guard !postures.isEmpty, let posture, posture != "closed" else { return "primary" }
    return "primary-1"
  }

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
      xpc_dictionary_set_uint64(payload, "target", touchTarget)
      service.send("IndigoDigitizerEvent", payload)
    } else if let legacy = legacyHID() {
      legacy.touch(first, second, down: phase != 2, edge: UInt32(edge))
    }
  }

  private var touchTarget: UInt64 {
    guard displayName != "primary" else { return 0 }
    if let target = touchTargets[displayName] { return target }
    let target = SimulatorRuntime.screens(device).first { $0.name == displayName }.map { UInt64($0.screenID) } ?? 0
    touchTargets[displayName] = target
    return target
  }

  private static func point(_ point: CGPoint) -> xpc_object_t {
    let value = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_double(value, "x", Double(point.x))
    xpc_dictionary_set_double(value, "y", Double(point.y))
    return value
  }

  static let buttons: [String: (page: UInt32, usage: UInt32)] = [
    "home": (0x0C, 0x40), "power": (0x0C, 0x30), "lock": (0x0C, 0x30), "siri": (0x0C, 0xCF),
    "volume-up": (0x0C, 0xE9), "volume-down": (0x0C, 0xEA), "action": (0x0B, 0x2D), "mute": (0x0B, 0x2E),
    "play-pause": (0x0C, 0xCD), "digital-crown": (0x0C, 0x40), "side-button": (0x0C, 0x95),
    "left-side-button": (0x0B, 0x2D), "menu": (0x0C, 0x86),
  ]

  func button(_ name: String, down: Bool) {
    let usage: (page: UInt32, usage: UInt32)?
    if name.hasPrefix("hid:") {
      let parts = name.split(separator: ":").compactMap { UInt32($0) }
      usage = parts.count == 2 ? (parts[0], parts[1]) : nil
    } else if name == "menu", family == "Apple TV" {
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

  func rotate(to orientation: ScreenSharingSimulatorOrientation) {
    guard canRotate, orientation != self.orientation else { return }
    self.orientation = orientation
    onChange?()
    let viaMotion = sendDeviceState(
      source: "orientation-picker-control", type: "enum", value: .string(Self.motionName(orientation)))
    if let service = orientationServiceIfAvailable() {
      let payload = xpc_dictionary_create(nil, nil, 0)
      let change = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_string(change, "_0", orientation.rawValue)
      xpc_dictionary_set_value(payload, "changeOrientation", change)
      let request = Unchecked(payload)
      queue.async { _ = service.request("OrientationRequest", request.value) }
    } else if !viaMotion {
      SimulatorRuntime.sendOrientationEvent(device: device, value: Self.gsEventValue(orientation))
    }
  }

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

  nonisolated static func hingeAngle(_ posture: String) -> Int? {
    switch posture {
    case "closed": 0
    case "book": 130
    case "open": 180
    default: nil
    }
  }

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
        self.hingeAngle = start + Int((Double(target - start) * eased).rounded())
        self.sendDeviceState(source: "hinge-slider-control", type: "range", value: .integer(self.hingeAngle))
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
  }

  @discardableResult
  private func sendDeviceState(source: String, type: String, value: DeviceStateValue) -> Bool {
    guard let service = vendorDefinedService() else { return false }
    let data = Self.deviceState(source: source, type: type, value: value)
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

  enum DeviceStateValue {
    case integer(Int)
    case string(String)
  }

  nonisolated static func deviceState(source: String, type: String, value: DeviceStateValue) -> Data {
    func string(_ text: String) -> String {
      let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
      return "<string>\(escaped)</string>"
    }
    let encoded =
      switch value {
      case .integer(let number): "<integer>\(number)</integer>"
      case .string(let text): string(text)
      }
    let entries = [("source", string(source)), ("type", string(type)), ("value", encoded)]
    return Data(("<dict>" + entries.map { "<key>\($0)</key>\($1)" }.joined() + "</dict>").utf8)
  }

  private func digitizerService() -> SimulatorRuntime.GuestService? {
    if digitizer == nil {
      digitizer = try? SimulatorRuntime.GuestService(
        device: device, feature: "com.apple.coredevice.feature.remote.hid.digitizer")
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
    let retained = Unchecked((digitizer, orientationService, vendorDefined, legacy))
    queue.asyncAfter(deadline: .now() + 1) { _ = retained }
    digitizer = nil
    orientationService = nil
    vendorDefined = nil
    self.legacy = nil
  }
}

struct Unchecked<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
