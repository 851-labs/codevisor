import Foundation
import Metal

final class MetalRecycler<Resource>: @unchecked Sendable {
  private struct Lent: @unchecked Sendable {
    let resource: Resource
  }

  private let lock = NSLock()
  private var free: [Resource] = []
  private var made = 0

  func take(orMake make: () throws -> Resource) rethrows -> Resource {
    if let resource = lock.withLock({ free.popLast() }) { return resource }

    lock.withLock { made += 1 }
    return try make()
  }

  func take(orMake make: () throws -> Resource, limit: Int) rethrows -> Resource? {
    let atLimit = lock.withLock { free.isEmpty && made >= limit }
    guard !atLimit else { return nil }

    return try take(orMake: make)
  }

  func recycle(_ resource: Resource, after commandBuffer: any MTLCommandBuffer) {
    let lent = Lent(resource: resource)
    commandBuffer.addCompletedHandler { _ in self.giveBack(lent) }
  }

  private func giveBack(_ lent: Lent) {
    lock.withLock { free.append(lent.resource) }
  }
}
