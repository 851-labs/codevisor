import CodevisorClient
import Foundation
import Synchronization

final class FakeSigner: Sendable {
  struct Failure: LocalizedError {
    var errorDescription: String? { "The app's key couldn't be read in this test." }
  }

  private struct State {
    var messages: [String] = []
    var fails = false
  }

  private let state = Mutex(State())

  var messages: [String] { state.withLock { $0.messages } }

  var signer: ScreenSharingStartSigner {
    ScreenSharingStartSigner(key: FakeMedia.address.endpointId) { [self] message in try sign(message) }
  }

  func failFromNowOn() {
    state.withLock { $0.fails = true }
  }

  static func signature(number: Int) -> String {
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
