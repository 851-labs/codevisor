import Foundation
import ScreenSharing

@MainActor
public final class ScreenSharingV2Channels {
  public typealias SendDatagram = @Sendable (ScreenSharingDatagramKind, Data) -> Bool

  public let control: ScreenSharingV2Channel<ScreenSharingControlMessage>
  public let clipboard: ScreenSharingV2Channel<ScreenSharingClipboardMessage>
  public let clipboardSharing: ScreenSharingV2Channel<ScreenSharingClipboardSharingMessage>
  public let display: ScreenSharingV2Channel<ScreenSharingDisplayMessage>
  public let videoFormat: ScreenSharingV2Channel<ScreenSharingVideoFormatMessage>
  public let cursor: ScreenSharingV2Channel<ScreenSharingCursorMessage>
  public let audio: ScreenSharingV2Channel<ScreenSharingAudioMessage>
  public let simulator: ScreenSharingV2Channel<ScreenSharingSimulatorMessage>
  private var accepting: Task<Void, Never>?

  public init(sendDatagram: @escaping SendDatagram) {
    control = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingControlMessage.decode),
      bufferedBytes: 16 * 1024)
    clipboard = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingClipboardMessage.decode),
      bufferedBytes: 1024 * 1024)
    clipboardSharing = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingClipboardSharingMessage.decode),
      bufferedBytes: 16 * 1024)
    display = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingDisplayMessage.decode), bufferedBytes: 16 * 1024)
    videoFormat = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingVideoFormatMessage.decode),
      bufferedBytes: 16 * 1024)
    cursor = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingCursorMessage.decode),
      bufferedBytes: 256 * 1024,
      datagrams: .init(
        carries: { if case .position = $0 { true } else { false } }, send: { sendDatagram(.cursor, $0) },
        settleAfter: .milliseconds(100)))
    audio = .init(
      codec: .init(encode: { $0.encoded() }, decode: ScreenSharingAudioMessage.decode), bufferedBytes: 16 * 1024,
      datagrams: .init(
        carries: { if case .packet = $0 { true } else { false } }, send: { sendDatagram(.audio, $0) }))
    simulator = .init(
      codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingSimulatorMessage.decode),
      bufferedBytes: 64 * 1024)
  }

  public func open(on connection: any ScreenSharingV2Connection, token: String) async throws {
    let stream = try await connection.openStream()
    try await stream.send(ScreenSharingV2Hello.request(token: token))
    try ScreenSharingV2Hello.verdict(try await stream.receive())
    attach(stream, kind: .control)
    for kind in ScreenSharingV2ChannelKind.allCases where kind != .control {
      let stream = try await connection.openStream()
      try await stream.send(Data([kind.rawValue]))
      attach(stream, kind: kind)
    }
  }

  public func accept(
    on connection: any ScreenSharingV2Connection, validate: @MainActor (String) -> String?
  ) async throws {
    let stream = try await connection.acceptStream()
    guard let token = ScreenSharingV2Hello.token(in: try await stream.receive()) else {
      throw ScreenSharingError.invalid("The viewer didn't present a screen-sharing token.")
    }
    if let refusal = validate(token) {
      try? await stream.send(ScreenSharingV2Hello.refused(refusal))
      await stream.finish()
      throw ScreenSharingError.invalid(refusal)
    }

    try await stream.send(ScreenSharingV2Hello.accepted)
    attach(stream, kind: .control)
    accepting = Task { [weak self] in
      while let stream = try? await connection.acceptStream() {
        guard let first = try? await stream.receive(), first.count == 1,
          let kind = ScreenSharingV2ChannelKind(rawValue: first[first.startIndex]), kind != .control
        else {
          await stream.finish()
          continue
        }
        guard let self else { return }

        self.attach(stream, kind: kind)
      }
    }
  }

  func receiveDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) {
    switch kind {
    case .cursor: cursor.receiveDatagram(payload)
    case .audio: audio.receiveDatagram(payload)
    }
  }

  public func close() {
    accepting?.cancel()
    control.close()
    clipboard.close()
    clipboardSharing.close()
    display.close()
    videoFormat.close()
    cursor.close()
    audio.close()
    simulator.close()
  }

  private func attach(_ stream: any ScreenSharingV2MessageStream, kind: ScreenSharingV2ChannelKind) {
    switch kind {
    case .control: control.attach(stream)
    case .clipboard: clipboard.attach(stream)
    case .clipboardSharing: clipboardSharing.attach(stream)
    case .display: display.attach(stream)
    case .videoFormat: videoFormat.attach(stream)
    case .cursor: cursor.attach(stream)
    case .audio: audio.attach(stream)
    case .simulator: simulator.attach(stream)
    }
  }
}

enum ScreenSharingV2Hello {
  private static let accept: UInt8 = 1
  private static let refuse: UInt8 = 0
  static let accepted = Data([accept])

  static func request(token: String) -> Data {
    Data([ScreenSharingV2ChannelKind.control.rawValue]) + Data(token.utf8)
  }

  static func token(in message: Data?) -> String? {
    guard let message, message.first == ScreenSharingV2ChannelKind.control.rawValue, message.count <= 257 else {
      return nil
    }

    return String(data: message.dropFirst(), encoding: .utf8)
  }

  static func refused(_ reason: String) -> Data {
    Data([refuse]) + Data(reason.prefix(512).utf8)
  }

  static func verdict(_ reply: Data?) throws {
    guard let reply, reply.first == accept else {
      let reason = reply.flatMap { String(data: $0.dropFirst(), encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
      throw ScreenSharingError.unavailable(reason ?? "The host Mac refused the screen-sharing connection.")
    }
  }
}
