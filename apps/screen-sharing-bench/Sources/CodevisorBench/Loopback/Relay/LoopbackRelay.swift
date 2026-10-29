import Dispatch
import ScreenSharingBench

final class LoopbackRelay: @unchecked Sendable {
  private static let feedbackSeedSalt: UInt64 = 0x5EED_FEED_BACC_0001

  let hostFacing: RelaySocket
  let viewerFacing: RelaySocket
  private let queue = DispatchQueue(label: "codevisor.bench.relay", qos: .userInteractive)
  private let timer: any DispatchSourceTimer
  private var media: BenchRelayLink<RelayDelivery>
  private var feedback: BenchRelayLink<RelayDelivery>
  private var hostAddress: BenchUDPAddress?
  private var viewerAddress: BenchUDPAddress?
  private var mappings: [BenchUDPAddress: RelayMapping] = [:]
  private var sources: [any DispatchSourceRead] = []

  init(conditions: BenchNetworkConditions, seed: UInt64, originNs: Int64) throws {
    let host = try RelaySocket()
    do {
      viewerFacing = try RelaySocket()
    } catch {
      host.close()
      throw error
    }
    hostFacing = host
    media = BenchRelayLink(conditions: conditions, seed: seed, originNs: originNs)
    feedback = BenchRelayLink(conditions: conditions, seed: seed ^ Self.feedbackSeedSalt, originNs: originNs)
    timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    timer.setEventHandler { [unowned self] in flushDue() }
    timer.activate()
    listen(on: hostFacing) { [unowned self] in forward(.feedback, $0, via: mapping(for: $0.sender, facing: hostFacing))
    }
    listen(on: viewerFacing) { [unowned self] in forward(.media, $0, via: mapping(for: $0.sender, facing: viewerFacing))
    }
  }

  func connect(host: BenchUDPAddress, viewer: BenchUDPAddress) {
    queue.sync {
      hostAddress = host
      viewerAddress = viewer
    }
  }

  var report: BenchRelayReport {
    queue.sync { BenchRelayReport(media: media.statistics, feedback: feedback.statistics) }
  }

  var mediaTraffic: BenchRelayTraffic {
    queue.sync { media.traffic }
  }

  func close() {
    queue.sync {
      timer.cancel()
      for source in sources { source.cancel() }
      sources = []
      mappings = [:]
    }
  }

  private func listen(on socket: RelaySocket, handle: @escaping (RelaySocket.Datagram) -> Void) {
    let source = DispatchSource.makeReadSource(fileDescriptor: socket.descriptor, queue: queue)
    source.setEventHandler { [unowned self] in
      while let datagram = socket.receive() { handle(datagram) }
      flushDue()
    }
    source.setCancelHandler { socket.close() }
    source.activate()
    sources.append(source)
  }

  private func mapping(for source: BenchUDPAddress, facing: RelaySocket) -> RelayMapping? {
    if let existing = mappings[source] { return existing }
    guard let socket = try? RelaySocket() else {
      BenchConsole.error("relay: no socket for \(source), its packets are dropped")
      return nil
    }

    let mapping = RelayMapping(socket: socket, source: source, facing: facing)
    mappings[source] = mapping
    let returning: RelayDirection = facing === hostFacing ? .media : .feedback
    listen(on: socket) { [unowned self] in offer(returning, $0.bytes, from: facing, to: source) }
    return mapping
  }

  private func forward(_ direction: RelayDirection, _ datagram: RelaySocket.Datagram, via mapping: RelayMapping?) {
    let destination = direction == .media ? viewerAddress : hostAddress
    guard let mapping, let destination else { return }

    offer(direction, datagram.bytes, from: mapping.socket, to: destination)
  }

  private func offer(
    _ direction: RelayDirection, _ bytes: [UInt8], from socket: RelaySocket, to target: BenchUDPAddress
  ) {
    let delivery = RelayDelivery(socket: socket, destination: target, bytes: bytes)
    let nowNs = BenchMachClock.nowNs()
    switch direction {
    case .media: media.offer(delivery, byteCount: bytes.count, atNs: nowNs)
    case .feedback: feedback.offer(delivery, byteCount: bytes.count, atNs: nowNs)
    }
  }

  private func flushDue() {
    let nowNs = BenchMachClock.nowNs()
    for delivery in media.takeDue(atNs: nowNs) + feedback.takeDue(atNs: nowNs) { delivery.send() }
    scheduleNextDue(after: nowNs)
  }

  private func scheduleNextDue(after nowNs: Int64) {
    guard let dueNs = [media.nextDueNs, feedback.nextDueNs].compactMap(\.self).min() else {
      timer.schedule(deadline: .distantFuture, leeway: .never)
      return
    }

    timer.schedule(deadline: .now() + .nanoseconds(Int(max(0, dueNs - nowNs))), leeway: .never)
  }
}
