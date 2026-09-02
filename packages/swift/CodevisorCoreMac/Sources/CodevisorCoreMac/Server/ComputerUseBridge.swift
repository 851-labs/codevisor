import AppKit
import ApplicationServices
import CodevisorCore
import Darwin
import Foundation
import ScreenCaptureKit

/// Authenticated, loopback-only Unix socket used by the bundled server for
/// macOS accessibility automation. The Node process never receives direct
/// Accessibility or Screen Recording entitlements; those stay in the app.
public final class ComputerUseBridge: @unchecked Sendable {
  public struct Configuration: Sendable {
    public let socketPath: String
    public let token: String
  }

  struct ElementRecord {
    let element: AXUIElement
    let frame: CGRect?
  }

  struct SnapshotRecord {
    let elements: [String: ElementRecord]
    let windowID: CGWindowID?
    let windowFrame: CGRect?
    let screenshotPixelSize: CGSize?
    let createdAt: UInt64
  }

  private let listenerQueue = DispatchQueue(
    label: "com.codevisor.computer-use.listener",
    qos: .userInitiated
  )
  private let clientQueue = DispatchQueue(
    label: "com.codevisor.computer-use.clients",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let supportDirectory: URL
  let lock = NSLock()
  private var listener: Int32 = -1
  private var configuration: Configuration?
  var snapshots: [String: [String: SnapshotRecord]] = [:]
  var latestSnapshotIDs: [String: String] = [:]
  var windowIDBySession: [String: CGWindowID] = [:]
  /// Windows whose element frames are published upside down, established
  /// once per window because the answer cannot change while it lives.
  var flippedContentWindows: [CGWindowID: Bool] = [:]

  public init(supportDirectory: URL = CodevisorAppVariant.serverDataDirectoryURL()) {
    self.supportDirectory = supportDirectory
  }

  deinit {
    stop()
  }

  public func start() throws -> Configuration {
    lock.lock()
    defer { lock.unlock() }
    if let configuration { return configuration }

    try FileManager.default.createDirectory(
      at: supportDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // sockaddr_un paths are short (104 bytes on macOS), while development
    // data directories are often nested deeply in a worktree. Derive a
    // stable, user-scoped socket in the system temporary directory and
    // keep the durable authentication token beside the server database.
    let socketPath = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "codevisor-cu-\(getuid())-\(Self.stablePathHash(supportDirectory.path)).sock"
      ).path
    let tokenURL = supportDirectory.appendingPathComponent("computer-use-token")
    let token: String
    if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty
    {
      token = existing
    } else {
      token = UUID().uuidString + UUID().uuidString
      try Data(token.utf8).write(to: tokenURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: tokenURL.path
      )
    }

    unlink(socketPath)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    do {
      try bindSocket(descriptor, path: socketPath)
      guard listen(descriptor, 8) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    } catch {
      Darwin.close(descriptor)
      unlink(socketPath)
      throw error
    }
    chmod(socketPath, 0o600)
    listener = descriptor
    let ready = Configuration(socketPath: socketPath, token: token)
    configuration = ready
    listenerQueue.async { [weak self] in self?.acceptLoop(descriptor, token: token) }
    return ready
  }

  public func stop() {
    lock.lock()
    let descriptor = listener
    listener = -1
    let socketPath = configuration?.socketPath
    configuration = nil
    snapshots.removeAll()
    latestSnapshotIDs.removeAll()
    windowIDBySession.removeAll()
    lock.unlock()
    if descriptor >= 0 {
      shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
    if let socketPath { unlink(socketPath) }
    ComputerUsePresentation.endAll()
  }

  private func bindSocket(_ descriptor: Int32, path: String) throws {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.initializeMemory(as: UInt8.self, repeating: 0)
      _ = path.utf8CString.withUnsafeBytes { source in
        source.copyBytes(to: bytes)
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, length)
      }
    }
    guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  }

  private func acceptLoop(_ descriptor: Int32, token: String) {
    while true {
      let client = accept(descriptor, nil, nil)
      if client < 0 { return }
      clientQueue.async { [weak self] in
        self?.serve(client, token: token)
        Darwin.close(client)
      }
    }
  }

  private static func stablePathHash(_ path: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in path.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    return String(hash, radix: 16)
  }

  private func serve(_ descriptor: Int32, token: String) {
    var authenticated = false
    var activeSessionIDs = Set<String>()
    defer {
      for sessionID in activeSessionIDs {
        ComputerUsePresentation.end(sessionID: sessionID)
      }
    }
    var pending = Data()
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = recv(descriptor, &bytes, bytes.count, 0)
      if count <= 0 { return }
      pending.append(bytes, count: count)
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending.prefix(upTo: newline)
        pending.removeSubrange(...newline)
        guard !line.isEmpty else { continue }
        let response: [String: Any]
        do {
          guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any]
          else { throw BridgeError("Invalid request") }
          let id = message["id"] as? String ?? ""
          if !authenticated {
            guard message["type"] as? String == "authenticate",
              message["token"] as? String == token
            else { throw BridgeError("Authentication failed") }
            authenticated = true
            response = ["id": id, "result": textResult("authenticated")]
          } else {
            if let sessionID = message["sessionId"] as? String, !sessionID.isEmpty {
              if message["type"] as? String == "closeSession" {
                activeSessionIDs.remove(sessionID)
              } else if message["type"] as? String == "tool" {
                activeSessionIDs.insert(sessionID)
              }
            }
            response = ["id": id, "result": try handle(message)]
          }
        } catch {
          let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
          response = [
            "id": object?["id"] as? String ?? "",
            "error": String(describing: error),
          ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        writeAll(descriptor, data + Data([0x0A]))
      }
    }
  }

  func activatePresentation(
    sessionID: String,
    agentLabel: String?,
    app: NSRunningApplication,
    window: AXUIElement,
    windowID: CGWindowID?
  ) {
    guard let windowFrame = frame(of: window) else { return }
    ComputerUsePresentation.activate(
      sessionID: sessionID,
      agentLabel: agentLabel,
      appName: app.localizedName ?? app.bundleIdentifier ?? "App",
      pid: app.processIdentifier,
      windowID: windowID,
      windowFrame: windowFrame
    )
  }

  func requireAccessibility(prompt: Bool) throws {
    if AXIsProcessTrusted() { return }
    if prompt {
      _ = AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      )
    }
    throw BridgeError("Enable Codevisor in System Settings → Privacy & Security → Accessibility")
  }
}

struct BridgeError: LocalizedError, CustomStringConvertible {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
  var description: String { message }
}

private func writeAll(_ descriptor: Int32, _ data: Data) {
  data.withUnsafeBytes { bytes in
    guard var address = bytes.baseAddress else { return }
    var remaining = bytes.count
    while remaining > 0 {
      let count = Darwin.write(descriptor, address, remaining)
      if count <= 0 { return }
      remaining -= count
      address = address.advanced(by: count)
    }
  }
}

func textResult(_ text: String) -> [String: Any] {
  ["content": [["type": "text", "text": text]]]
}

func json(_ value: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

func int(_ value: Any?) -> Int? {
  (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
}

func double(_ value: Any?) -> Double? {
  (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
}

/// Reading another process's AX tree is an IPC request, but reading our own
/// tree calls straight back into AppKit and SwiftUI on the calling thread.
/// Keep those self-targeted callbacks on main without moving the bridge's
/// socket, screenshot, or encoding work there as well.
func computerUseAccessibilityReadRequiresMainThread(
  targetPID: pid_t?,
  currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
  isMainThread: Bool = Thread.isMainThread
) -> Bool {
  !isMainThread && (targetPID == nil || targetPID == currentPID)
}

private final class ComputerUseAccessibilityReadBox<Value>: @unchecked Sendable {
  let operation: () -> Value
  var value: Value?

  init(operation: @escaping () -> Value) {
    self.operation = operation
  }
}

/// Runs one AX read on the thread that owns the target UI. Callers should wrap
/// a whole tree traversal when possible; the lower-level attribute helpers use
/// this too so a future read path cannot accidentally reintroduce self-target
/// access from a bridge worker.
func computerUsePerformAccessibilityRead<Value>(
  targetPID: pid_t?,
  _ operation: @escaping () -> Value
) -> Value {
  guard
    computerUseAccessibilityReadRequiresMainThread(targetPID: targetPID)
  else { return operation() }

  let box = ComputerUseAccessibilityReadBox(operation: operation)
  DispatchQueue.main.sync {
    box.value = box.operation()
  }
  return box.value!
}

private func computerUseAccessibilityElementPID(_ element: AXUIElement) -> pid_t? {
  var pid: pid_t = 0
  return AXUIElementGetPid(element, &pid) == .success ? pid : nil
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  let targetPID = computerUseAccessibilityElementPID(element)
  return computerUsePerformAccessibilityRead(targetPID: targetPID) {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
      ? value
      : nil
  }
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
  copyAttribute(element, name) as? String
}

func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
  copyAttribute(element, name) as! AXUIElement?
}

func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
  copyAttribute(element, name) as? [AXUIElement] ?? []
}

func frame(of element: AXUIElement) -> CGRect? {
  guard let positionValue = copyAttribute(element, kAXPositionAttribute),
    let sizeValue = copyAttribute(element, kAXSizeAttribute),
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else { return nil }
  let position = positionValue as! AXValue
  let size = sizeValue as! AXValue
  var origin = CGPoint.zero
  var dimensions = CGSize.zero
  guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions)
  else { return nil }
  return CGRect(origin: origin, size: dimensions)
}

func frameObject(_ frame: CGRect) -> [String: Double] {
  ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
}

extension NSLock {
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock(); defer { unlock() }
    return try operation()
  }
}
