import Foundation

public enum RFBClientMessage: Sendable, Equatable {
  case setPixelFormat(RFBPixelFormat)
  case setEncodings([Int32])
  case framebufferUpdateRequest(incremental: Bool, RFBRectangle)
  case keyEvent(keysym: UInt32, down: Bool)
  case pointerEvent(buttons: UInt8, x: UInt16, y: UInt16)
  case clientCutText(String)
  case enableContinuousUpdates(enable: Bool, RFBRectangle)
  case fence(flags: UInt32, payload: [UInt8])
  case setDesktopSize(width: Int, height: Int, screens: [RFBScreen])
  case extendedClipboard(RFBExtendedClipboard.Message)

  public var encoded: [UInt8] {
    var writer = RFBByteWriter()
    switch self {
    case .setPixelFormat(let format):
      writer.u8(0); writer.pad(3); writer.append(format.encoded)
    case .setEncodings(let encodings):
      writer.u8(2); writer.pad(1); writer.u16(UInt16(clamping: encodings.count))
      for encoding in encodings.prefix(Int(UInt16.max)) { writer.s32(encoding) }
    case .framebufferUpdateRequest(let incremental, let rect):
      writer.u8(3); writer.u8(incremental ? 1 : 0)
      writer.u16(UInt16(clamping: rect.x)); writer.u16(UInt16(clamping: rect.y))
      writer.u16(UInt16(clamping: rect.width)); writer.u16(UInt16(clamping: rect.height))
    case .keyEvent(let keysym, let down):
      writer.u8(4); writer.u8(down ? 1 : 0); writer.pad(2); writer.u32(keysym)
    case .pointerEvent(let buttons, let x, let y):
      writer.u8(5); writer.u8(buttons); writer.u16(x); writer.u16(y)
    case .clientCutText(let text):
      let latin1 = RFBLatin1.encode(text)
      writer.u8(6); writer.pad(3); writer.u32(UInt32(clamping: latin1.count)); writer.append(latin1)
    case .enableContinuousUpdates(let enable, let rect):
      writer.u8(150); writer.u8(enable ? 1 : 0)
      writer.u16(UInt16(clamping: rect.x)); writer.u16(UInt16(clamping: rect.y))
      writer.u16(UInt16(clamping: rect.width)); writer.u16(UInt16(clamping: rect.height))
    case .fence(let flags, let payload):
      writer.u8(248); writer.pad(3); writer.u32(flags)
      writer.u8(UInt8(min(payload.count, RFBFence.maximumPayload)));
      writer.append(Array(payload.prefix(RFBFence.maximumPayload)))
    case .setDesktopSize(let width, let height, let screens):
      writer.u8(251); writer.pad(1)
      writer.u16(UInt16(clamping: width)); writer.u16(UInt16(clamping: height))
      writer.u8(UInt8(clamping: screens.count)); writer.pad(1)
      for screen in screens.prefix(255) { RFBScreenLayout.write(screen, into: &writer) }
    case .extendedClipboard(let message):
      let payload = (try? RFBExtendedClipboard.encode(message)) ?? []
      writer.u8(6); writer.pad(3); writer.s32(-Int32(clamping: payload.count)); writer.append(payload)
    }
    return writer.bytes
  }

  package static func read(from stream: RFBInputStream) async throws -> RFBClientMessage {
    switch try await stream.u8() {
    case 0:
      try await stream.skip(3)
      return .setPixelFormat(try RFBPixelFormat.decode(try await stream.bytes(16)))
    case 2:
      try await stream.skip(1)
      let count = Int(try await stream.u16())
      var encodings: [Int32] = []
      for _ in 0..<count { encodings.append(try await stream.s32()) }
      return .setEncodings(encodings)
    case 3:
      let incremental = try await stream.u8() != 0
      let x = Int(try await stream.u16()), y = Int(try await stream.u16())
      let width = Int(try await stream.u16()), height = Int(try await stream.u16())
      return .framebufferUpdateRequest(incremental: incremental, RFBRectangle(x: x, y: y, width: width, height: height))
    case 4:
      let down = try await stream.u8() != 0
      try await stream.skip(2)
      return .keyEvent(keysym: try await stream.u32(), down: down)
    case 5:
      let buttons = try await stream.u8()
      return .pointerEvent(buttons: buttons, x: try await stream.u16(), y: try await stream.u16())
    case 6:
      try await stream.skip(3)
      let length = Int(try await stream.s32())
      if length < 0 {
        return .extendedClipboard(try RFBExtendedClipboard.decode(try await stream.bytes(-length)))
      }
      return .clientCutText(RFBLatin1.decode(try await stream.bytes(length)))
    case 150:
      let enable = try await stream.u8() != 0
      let x = Int(try await stream.u16()), y = Int(try await stream.u16())
      let width = Int(try await stream.u16()), height = Int(try await stream.u16())
      return .enableContinuousUpdates(enable: enable, RFBRectangle(x: x, y: y, width: width, height: height))
    case 248:
      let (flags, payload) = try await RFBFence.read(from: stream)
      return .fence(flags: flags, payload: payload)
    case 251:
      try await stream.skip(1)
      let width = Int(try await stream.u16()), height = Int(try await stream.u16())
      let count = Int(try await stream.u8())
      try await stream.skip(1)
      return .setDesktopSize(width: width, height: height, screens: try await RFBScreenLayout.read(count, from: stream))
    case let type:
      throw RFBError.malformed("unknown client message \(type)")
    }
  }
}

public enum RFBScreenLayout {
  public static func write(_ screen: RFBScreen, into writer: inout RFBByteWriter) {
    writer.u32(screen.id)
    writer.u16(UInt16(clamping: screen.x)); writer.u16(UInt16(clamping: screen.y))
    writer.u16(UInt16(clamping: screen.width)); writer.u16(UInt16(clamping: screen.height))
    writer.u32(screen.flags)
  }

  package static func read(_ count: Int, from stream: RFBInputStream) async throws -> [RFBScreen] {
    var screens: [RFBScreen] = []
    for _ in 0..<count {
      let id = try await stream.u32()
      let x = Int(try await stream.u16()), y = Int(try await stream.u16())
      let width = Int(try await stream.u16()), height = Int(try await stream.u16())
      screens.append(RFBScreen(id: id, x: x, y: y, width: width, height: height, flags: try await stream.u32()))
    }
    return screens
  }
}

public enum RFBFence {
  public static let blockBefore: UInt32 = 1 << 0
  public static let blockAfter: UInt32 = 1 << 1
  public static let syncNext: UInt32 = 1 << 2
  public static let request: UInt32 = 1 << 31
  public static let understood: UInt32 = blockBefore | blockAfter | syncNext
  public static let maximumPayload = 64

  package static func read(from stream: RFBInputStream) async throws -> (flags: UInt32, payload: [UInt8]) {
    try await stream.skip(3)
    let flags = try await stream.u32()
    let length = Int(try await stream.u8())
    guard length <= maximumPayload else { throw RFBError.malformed("fence payload of \(length) bytes") }
    return (flags, try await stream.bytes(length))
  }
}

public enum RFBLatin1 {
  public static func encode(_ text: String) -> [UInt8] {
    text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.map {
      $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?")
    }
  }
  public static func decode(_ bytes: [UInt8]) -> String {
    String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) })).replacingOccurrences(of: "\r\n", with: "\n")
  }
}
