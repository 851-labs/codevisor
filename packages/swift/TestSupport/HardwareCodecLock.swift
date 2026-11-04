import Foundation
import Synchronization
import Testing

public struct HardwareCodecLock: SuiteTrait, TestTrait, TestScoping {
  static let waitLimitSeconds = 45
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
    try #require(descriptor >= 0, "Can't open \(path): \(String(cString: strerror(errno))).")
    guard await locked(descriptor) else { try giveUp(descriptor) }

    recordHolder(in: descriptor)
    return descriptor
  }

  private static func locked(_ descriptor: Int32) async -> Bool {
    await withCheckedContinuation { continuation in
      let waiter = ResumeOnce(continuation)
      Thread.detachNewThread {
        let acquired = exclusiveLock(descriptor)
        if !waiter.resume(with: acquired) { close(descriptor) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(waitLimitSeconds)) {
        waiter.resume(with: false)
      }
    }
  }

  private static func exclusiveLock(_ descriptor: Int32) -> Bool {
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { return false }
    }
    return true
  }

  private static func giveUp(_ descriptor: Int32) throws -> Never {
    gaveUp.store(true, ordering: .relaxed)
    try Test.cancel(
      "Skipped: couldn't get the hardware codec lock (\(path)) in \(waitLimitSeconds) s; \(holder(in: descriptor)) last held it. A hung test process may be holding it."
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
