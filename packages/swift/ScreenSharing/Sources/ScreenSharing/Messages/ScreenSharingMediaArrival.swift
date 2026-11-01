import Foundation

package typealias ScreenSharingReceivedMediaBytes = @MainActor () async -> Int64?

package struct ScreenSharingMediaArrival {
  private var received: Int64?

  package init() {}

  package mutating func record(_ bytes: Int64?) -> Bool {
    guard let bytes else { return false }
    defer { received = bytes }
    guard let received else { return false }
    return bytes > received
  }
}
