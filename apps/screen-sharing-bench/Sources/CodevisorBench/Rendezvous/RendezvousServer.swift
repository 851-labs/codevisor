import Darwin
import Synchronization

final class RendezvousServer: Sendable {
  private static let acceptTimeout = Duration.seconds(1)

  private struct Waiting {
    let connection: SignalingConnection
    let arrival: RendezvousArrival
  }

  private let waiting = Mutex<[String: [Waiting]]>([:])

  @concurrent
  static func serve(port: UInt16, for duration: Duration) async throws {
    let listener = try SignalingSocket.listen(port: port)
    defer { close(listener) }

    BenchConsole.error("rendezvous listening on TCP port \(port)")
    let server = RendezvousServer()
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
      guard let connection = try? SignalingSocket.accept(on: listener, timeout: acceptTimeout) else { continue }

      Task { await server.admit(connection) }
    }
  }

  @concurrent
  private func admit(_ connection: SignalingConnection) async {
    guard let arrival = try? connection.receive(RendezvousArrival.self) else { return }

    let everyone = waiting.withLock { waiting -> [Waiting]? in
      let present =
        waiting[arrival.barrier, default: []].filter {
          $0.arrival.party != arrival.party && !$0.connection.isClosedByPeer
        }
        + [Waiting(connection: connection, arrival: arrival)]
      guard present.count == RendezvousArrival.Party.allCases.count else {
        waiting[arrival.barrier] = present
        return nil
      }

      waiting[arrival.barrier] = nil
      return present
    }
    guard let everyone else { return }

    BenchConsole.error("rendezvous: everyone reached \(arrival.barrier)")
    release(everyone, at: arrival.barrier)
  }

  private func release(_ everyone: [Waiting], at barrier: String) {
    var statuses: [String: String] = [:]
    for waiting in everyone { statuses[waiting.arrival.party.rawValue] = waiting.arrival.status }
    let meeting = RendezvousMeeting(barrier: barrier, statuses: statuses)
    for waiting in everyone { try? waiting.connection.send(meeting) }
  }
}
