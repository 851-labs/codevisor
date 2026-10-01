import Foundation

extension TerminalTransport {
  /// Receives and decodes frames off the main actor (frames arrive at very
  /// high frequency during builds and can be up to 8MB), including the
  /// renderer's bytes, and queues them in receive order. The main actor
  /// drains the queue in one hop however many frames arrived meanwhile;
  /// see `TerminalInboundFrames`.
  nonisolated func receiveLoop(
    _ socket: any ServerWebSocketConnecting, into inbound: TerminalInboundFrames
  ) async {
    let decoder = JSONDecoder()
    while !Task.isCancelled {
      let item: TerminalInboundFrames.Item
      do {
        let message = try await socket.receive()
        let frame: InboundTerminalFrame? =
          switch message {
          case .string(let text): Self.decodeTextFrame(text, decoder: decoder)
          case .data(let data): Self.decodeBinaryOutput(data)
          }
        guard let frame else { continue }
        item = .frame(frame)
      } catch {
        item = .failed
      }
      if inbound.append(item) {
        Task { @MainActor [weak self] in self?.drainInbound(inbound, from: socket) }
      }
      if case .failed = item { return }
      await inbound.waitForCapacity()
    }
  }

  nonisolated private static func decodeTextFrame(_ text: String, decoder: JSONDecoder) -> InboundTerminalFrame? {
    guard var frame = try? decoder.decode(TerminalServerFrame.self, from: Data(text.utf8)) else { return nil }
    let output = frame.type == "output" ? frame.data.map { TerminalOutput(text: $0) } : nil
    if output != nil { frame.data = nil }
    return InboundTerminalFrame(frame: frame, output: output)
  }

  /// Protocol 2 output: kind byte (1 output, 2 reset), sequence number as a
  /// big-endian u64, then UTF-8 output.
  nonisolated private static func decodeBinaryOutput(_ data: Data) -> InboundTerminalFrame? {
    guard data.count >= 9 else { return nil }
    let start = data.startIndex
    let kind = data[start]
    guard kind == 1 || kind == 2 else { return nil }
    let seq = data[(start + 1)..<(start + 9)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    let bytes = [UInt8](data[(start + 9)...])
    return InboundTerminalFrame(
      frame: TerminalServerFrame(type: "output", seq: Int(seq), reset: kind == 2 ? true : nil),
      output: TerminalOutput(text: String(decoding: bytes, as: UTF8.self), bytes: bytes))
  }
}
