import AppKit
import ApplicationServices
import Foundation

private typealias SLPSPostEventRecordToFunction =
  @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
private typealias GetProcessForPIDFunction =
  @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum ComputerUseActivationEvent {
  case activated
  case deactivated

  var recordSubtype: UInt8 {
    switch self {
    case .activated: 1
    case .deactivated: 2
    }
  }
}

func computerUseActivationRecord(_ event: ComputerUseActivationEvent, windowID: CGWindowID) -> [UInt8] {
  var record = [UInt8](repeating: 0, count: 0xf8)
  record[0x04] = 0xf8
  record[0x08] = 0x0d
  record[0x8a] = event.recordSubtype
  withUnsafeBytes(of: windowID.littleEndian) { bytes in
    for (offset, byte) in bytes.enumerated() { record[0x3c + offset] = byte }
  }
  return record
}

func computerUseMakeKeyRecords(windowID: CGWindowID) -> [[UInt8]] {
  [UInt8(0x01), 0x02].map { kind in
    var record = [UInt8](repeating: 0, count: 0xf8)
    record[0x04] = 0xf8
    record[0x08] = kind
    record[0x3a] = 0x10
    for offset in 0x20..<0x30 { record[offset] = 0xff }
    withUnsafeBytes(of: windowID.littleEndian) { bytes in
      for (offset, byte) in bytes.enumerated() { record[0x3c + offset] = byte }
    }
    return record
  }
}

func computerUseHasOpenMenuWindow(pid: pid_t) -> Bool {
  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
  return windows.contains {
    ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
      && $0[kCGWindowLayer as String] as? Int == menuLevel
  }
}

struct ComputerUseActivationHolds {
  private var sessionsByPID: [pid_t: Set<String>] = [:]

  mutating func hold(pid: pid_t, sessionID: String) {
    sessionsByPID[pid, default: []].insert(sessionID)
  }

  mutating func release(sessionID: String) -> [pid_t] {
    var released: [pid_t] = []
    for (pid, sessions) in sessionsByPID where sessions.contains(sessionID) {
      let remaining = sessions.subtracting([sessionID])
      if remaining.isEmpty {
        sessionsByPID.removeValue(forKey: pid)
        released.append(pid)
      } else {
        sessionsByPID[pid] = remaining
      }
    }
    return released.sorted()
  }

  func isHeld(_ pid: pid_t) -> Bool { sessionsByPID[pid] != nil }
}

final class ComputerUseSyntheticActivation: @unchecked Sendable {
  static let shared = ComputerUseSyntheticActivation()

  private let postEventRecord: SLPSPostEventRecordToFunction?
  private let processForPID: GetProcessForPIDFunction?
  private let lock = NSLock()
  private var holds = ComputerUseActivationHolds()

  private init() {
    func resolve<T>(_ path: String, _ name: String, as type: T.Type) -> T? {
      let handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL)
      guard let symbol = name.withCString({ dlsym(handle, $0) }) else { return nil }
      return unsafeBitCast(symbol, to: type)
    }
    postEventRecord = resolve(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLPSPostEventRecordTo",
      as: SLPSPostEventRecordToFunction.self)
    processForPID = resolve(
      "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", "GetProcessForPID",
      as: GetProcessForPIDFunction.self)
  }

  func hold(app: NSRunningApplication, sessionID: String, windowID: CGWindowID?, forKeyboard: Bool = false) {
    let pid = app.processIdentifier
    guard pid != ProcessInfo.processInfo.processIdentifier else { return }
    lock.withLock { holds.hold(pid: pid, sessionID: sessionID) }
    guard !app.isActive else { return }
    let activating = !believesActive(pid)
    if activating { post(computerUseActivationRecord(.activated, windowID: windowID ?? 0), pid: pid) }
    guard let windowID, activating || (forKeyboard && !computerUseHasOpenMenuWindow(pid: pid)) else { return }
    for record in computerUseMakeKeyRecords(windowID: windowID) { post(record, pid: pid) }
  }

  func release(sessionID: String) {
    let released = lock.withLock { holds.release(sessionID: sessionID) }
    for pid in released {
      guard let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { continue }
      post(computerUseActivationRecord(.deactivated, windowID: 0), pid: pid)
    }
  }

  private func believesActive(_ pid: pid_t) -> Bool {
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 1)
    return copyAttribute(application, kAXFrontmostAttribute) as? Bool == true
  }

  private func post(_ record: [UInt8], pid: pid_t) {
    guard let postEventRecord, let processForPID else { return }
    var process = ProcessSerialNumber()
    guard processForPID(pid, &process) == noErr else { return }
    var record = record
    _ = record.withUnsafeMutableBufferPointer { postEventRecord(&process, $0.baseAddress!) }
  }
}
