import CodevisorClient
import Foundation
import Network

public enum LocalNetworkPermissionProbe {
  private static let discardPort: NWEndpoint.Port = 9
  private static let denialSettleDelay: Duration = .seconds(2)

  public static func permissions() -> AsyncStream<LocalNetworkPermission> {
    guard let target = LocalNetworkProbeTarget.address(in: LocalIPv4Network.current()) else {
      return AsyncStream {
        $0.yield(.unavailable); $0.finish()
      }
    }
    return settled(pathReadings(to: target))
  }

  private static func pathReadings(to target: String) -> AsyncStream<LocalNetworkPermission> {
    AsyncStream { continuation in
      let connection = NWConnection(host: NWEndpoint.Host(target), port: discardPort, using: .udp)
      connection.pathUpdateHandler = { continuation.yield(permission(on: $0)) }
      continuation.onTermination = { _ in connection.cancel() }
      connection.start(queue: DispatchQueue(label: "codevisor.local-network-probe"))
    }
  }

  private static func permission(on path: NWPath) -> LocalNetworkPermission {
    if path.status == .satisfied { return .allowed }
    if path.unsatisfiedReason == .localNetworkDenied { return .denied }
    return .unavailable
  }

  private static func settled(
    _ readings: AsyncStream<LocalNetworkPermission>
  ) -> AsyncStream<LocalNetworkPermission> {
    AsyncStream { continuation in
      let task = Task {
        var pendingDenial: Task<Void, Never>?
        for await reading in readings {
          pendingDenial?.cancel()
          pendingDenial = report(reading, to: continuation)
        }
        pendingDenial?.cancel()
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func report(
    _ reading: LocalNetworkPermission,
    to continuation: AsyncStream<LocalNetworkPermission>.Continuation
  ) -> Task<Void, Never>? {
    guard reading == .denied else {
      continuation.yield(reading)
      return nil
    }
    return Task {
      guard (try? await Task.sleep(for: denialSettleDelay)) != nil else { return }
      continuation.yield(.denied)
    }
  }
}
