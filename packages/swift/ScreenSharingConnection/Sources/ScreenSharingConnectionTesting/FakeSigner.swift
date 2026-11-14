import CodevisorClient
import Foundation
import Synchronization

public final class FakeSigner: Sendable {
  public struct Failure: LocalizedError {
    public init() {}

    public var errorDescription: String? { "The app's key couldn't be read in this test." }
  }

  private struct State {
    var messages: [String] = []
    var fails = false
  }

  private let state = Mutex(State())

  public init() {}

  public var messages: [String] { state.withLock { $0.messages } }

  public var signer: ScreenSharingStartSigner {
    ScreenSharingStartSigner(key: FakeMedia.address.endpointId) { [self] message in try sign(message) }
  }

  public func failFromNowOn() {
    state.withLock { $0.fails = true }
  }

  public static func signature(number: Int) -> String {
    String(repeating: String(format: "%02x", number), count: 64)
  }

  private func sign(_ message: Data) throws -> Data {
    try state.withLock { state in
      if state.fails { throw Failure() }
      state.messages.append(String(decoding: message, as: UTF8.self))
      return Data(repeating: UInt8(state.messages.count), count: 64)
    }
  }
}
