import Foundation

package typealias ScreenSharingReceivedMediaBytes = @MainActor () async -> Int64?

@MainActor
package struct ScreenSharingMediaArrival {
  private let receivedBytes: ScreenSharingReceivedMediaBytes
  private var received: Int64?

  package init(_ receivedBytes: @escaping ScreenSharingReceivedMediaBytes) {
    self.receivedBytes = receivedBytes
  }

  package mutating func start() async {
    received = await receivedBytes()
  }

  package mutating func arrivedSinceLastSample() async -> Bool {
    guard let bytes = await receivedBytes() else { return false }
    defer { received = bytes }
    guard let received else { return false }
    return bytes > received
  }
}
