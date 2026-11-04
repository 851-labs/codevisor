import Foundation
import Synchronization
import Testing

public struct HardwareCodecLock: SuiteTrait, TestTrait, TestScoping {
  static let waitLimit = Duration.seconds(120)
  private static let pollInterval = Duration.milliseconds(50)
  private static let path = NSTemporaryDirectory() + "codevisor-hardware-codec.lock"
  private static let gaveUp = Atomic(false)

  public var isRecursive: Bool { true }

  public func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    guard testCase != nil else { return try await function() }

    let descriptor = try await Self.acquire()
    defer { close(descriptor) }
    try await function()
  }

  private static func acquire() async throws -> Int32 {
    if gaveUp.load(ordering: .relaxed) { try Test.cancel("Skipped: an earlier test couldn't get \(path).") }

    let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
    let deadline = ContinuousClock.now + waitLimit
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK {
      guard ContinuousClock.now < deadline, !Task.isCancelled else { try giveUp(descriptor) }

      try? await Task.sleep(for: pollInterval)
    }
    recordHolder(in: descriptor)
    return descriptor
  }

  private static func giveUp(_ descriptor: Int32) throws -> Never {
    let holder = holder(in: descriptor)
    close(descriptor)
    gaveUp.store(true, ordering: .relaxed)
    try Test.cancel(
      "Skipped: \(holder) has held the hardware codec lock (\(path)) for over \(waitLimit). A hung test process may be holding it."
    )
  }

  private static func recordHolder(in descriptor: Int32) {
    let pid = Array("\(getpid())".utf8)
    ftruncate(descriptor, 0)
    _ = pwrite(descriptor, pid, pid.count, 0)
  }

  private static func holder(in descriptor: Int32) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let count = pread(descriptor, &bytes, bytes.count, 0)
    guard count > 0, let pid = String(bytes: bytes.prefix(count), encoding: .utf8) else { return "another process" }

    return "process \(pid)"
  }
}

extension Trait where Self == HardwareCodecLock {
  public static var hardwareCodecLock: Self { HardwareCodecLock() }
}
