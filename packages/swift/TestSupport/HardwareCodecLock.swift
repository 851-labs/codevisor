import Foundation
import Testing

public struct HardwareCodecLock: SuiteTrait, TestTrait, TestScoping {
  public var isRecursive: Bool { true }

  public func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    guard testCase != nil else { return try await function() }

    let descriptor = await Self.acquire()
    defer { close(descriptor) }
    try await function()
  }

  private static func acquire() async -> Int32 {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        let descriptor = open(NSTemporaryDirectory() + "codevisor-hardware-codec.lock", O_CREAT | O_RDWR, 0o644)
        flock(descriptor, LOCK_EX)
        continuation.resume(returning: descriptor)
      }
    }
  }
}

extension Trait where Self == HardwareCodecLock {
  public static var hardwareCodecLock: Self { HardwareCodecLock() }
}
