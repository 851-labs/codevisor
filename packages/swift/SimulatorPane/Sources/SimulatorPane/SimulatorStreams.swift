import Foundation
import ScreenSharingConnection

@MainActor
final class SimulatorStreams {
  static let shared = SimulatorStreams()

  private struct Key: Hashable {
    let machineId: String
    let udid: String
  }

  private var streams: [Key: SimulatorSharedStream] = [:]

  func stream(machineId: String, udid: String, source: SimulatorStreamSource) -> SimulatorStream {
    let key = Key(machineId: machineId, udid: udid)
    return SimulatorStream(
      machineName: source.machineName,
      join: { [weak self] in self?.join(key, source) },
      leave: { [weak self] in self?.leave(key, $0, source) })
  }

  private func join(_ key: Key, _ source: SimulatorStreamSource) -> SimulatorSharedStream? {
    if let existing = streams[key], !existing.connection.isEnded { return existing }

    let target = SimulatorStreamSource.target(udid: key.udid)
    guard let connection = source.connection(target) else { return nil }

    let stream = SimulatorSharedStream(connection: connection)
    streams[key] = stream
    return stream
  }

  private func leave(_ key: Key, _ stream: SimulatorSharedStream, _ source: SimulatorStreamSource) {
    guard stream.isUnused, streams[key] === stream else { return }

    streams[key] = nil
    source.end(SimulatorStreamSource.target(udid: key.udid))
  }
}
