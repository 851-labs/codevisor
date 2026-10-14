import Foundation
import Synchronization

public final class CloudReleaseChannel: Sendable {
  public static let shared = CloudReleaseChannel()

  private let alpha = Mutex(false)

  public init(alpha: Bool = false) {
    self.alpha.withLock { $0 = alpha }
  }

  public var isAlpha: Bool {
    get { alpha.withLock { $0 } }
    set { alpha.withLock { $0 = newValue } }
  }

  var wireValue: String { isAlpha ? "alpha" : "stable" }
}
