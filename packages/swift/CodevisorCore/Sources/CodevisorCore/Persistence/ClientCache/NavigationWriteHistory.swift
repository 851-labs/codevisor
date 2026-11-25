import Foundation

final class NavigationWriteHistory: @unchecked Sendable {
  private let lock = NSLock()
  private var written: [String: ServerNavigationSnapshot] = [:]

  func previous(machineId: String) -> ServerNavigationSnapshot? {
    lock.withLock { written[machineId] }
  }

  func record(_ snapshot: ServerNavigationSnapshot?, machineId: String) {
    lock.withLock { written[machineId] = snapshot }
  }

  func takeAll() -> [String: ServerNavigationSnapshot] {
    lock.withLock {
      defer { written = [:] }
      return written
    }
  }
}
