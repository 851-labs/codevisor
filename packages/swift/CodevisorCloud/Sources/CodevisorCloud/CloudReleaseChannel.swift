import Foundation
import Synchronization

/// The app's update channel, as the cloud hub needs it at every hello: the hub
/// turns the tunnel on for devices on the Alpha channel only
/// (docs/plans/codevisor-tunnel.md). The app sets it from its Alpha-updates
/// preference; a change applies on the hub connection's next hello.
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

  /// The hello `releaseChannel` value.
  var wireValue: String { isAlpha ? "alpha" : "stable" }
}
