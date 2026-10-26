import Foundation

public enum RFBError: Error, LocalizedError, Sendable, Equatable {
  case connectionClosed
  case protocolMismatch(String)
  case securityUnsupported([UInt8])
  case authenticationFailed(String)
  case unsupportedEncoding(Int32)
  case malformed(String)
  case transport(String)

  public var errorDescription: String? {
    switch self {
    case .connectionClosed: "The VNC server closed the connection."
    case .protocolMismatch(let detail): "Not a VNC server: \(detail)"
    case .securityUnsupported(let types):
      types.contains(RFBSecurityType.appleRemoteDesktop.rawValue)
        ? "This Mac only accepts Apple Remote Desktop sign-in. Enable “VNC viewers may control screen with password” in Screen Sharing settings."
        : "The VNC server requires an unsupported authentication method (\(types.map(String.init).joined(separator: ", ")))."
    case .authenticationFailed(let reason): reason
    case .unsupportedEncoding(let encoding): "The VNC server sent an unsupported encoding (\(encoding))."
    case .malformed(let detail): "The VNC server sent an invalid message: \(detail)"
    case .transport(let detail): detail
    }
  }
}

public struct RFBProtocolVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public init(major: Int, minor: Int) { self.major = major; self.minor = minor }
  public static let v3_3 = Self(major: 3, minor: 3)
  public static let v3_7 = Self(major: 3, minor: 7)
  public static let v3_8 = Self(major: 3, minor: 8)

  public var encoded: [UInt8] { Array(description.utf8) }
  public var description: String {
    "RFB " + String(format: "%03d.%03d", major, minor) + "\n"
  }
  public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor) < (rhs.major, rhs.minor) }

  var negotiated: RFBProtocolVersion {
    if self >= .v3_8 { return .v3_8 }
    if self >= .v3_7 { return .v3_7 }
    return .v3_3
  }

  public static func parse(_ bytes: [UInt8]) -> RFBProtocolVersion? {
    guard bytes.count == 12, bytes.starts(with: Array("RFB ".utf8)), bytes[7] == UInt8(ascii: "."),
      bytes[11] == UInt8(ascii: "\n"), let major = Int(String(decoding: bytes[4..<7], as: UTF8.self)),
      let minor = Int(String(decoding: bytes[8..<11], as: UTF8.self))
    else { return nil }
    return RFBProtocolVersion(major: major, minor: minor)
  }
}

public enum RFBSecurityType: UInt8, Sendable {
  case none = 1
  case vncAuthentication = 2
  case appleRemoteDesktop = 30
}

public struct RFBPixelFormat: Sendable, Equatable {
  public var bitsPerPixel: UInt8
  public var depth: UInt8
  public var bigEndian: Bool
  public var trueColour: Bool
  public var redMax: UInt16
  public var greenMax: UInt16
  public var blueMax: UInt16
  public var redShift: UInt8
  public var greenShift: UInt8
  public var blueShift: UInt8

  public init(
    bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColour: Bool, redMax: UInt16, greenMax: UInt16,
    blueMax: UInt16, redShift: UInt8, greenShift: UInt8, blueShift: UInt8
  ) {
    self.bitsPerPixel = bitsPerPixel
    self.depth = depth
    self.bigEndian = bigEndian
    self.trueColour = trueColour
    self.redMax = redMax
    self.greenMax = greenMax
    self.blueMax = blueMax
    self.redShift = redShift
    self.greenShift = greenShift
    self.blueShift = blueShift
  }

  public static let bgra32 = RFBPixelFormat(
    bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true, redMax: 255, greenMax: 255, blueMax: 255,
    redShift: 16, greenShift: 8, blueShift: 0)

  public var encoded: [UInt8] {
    var writer = RFBByteWriter()
    writer.u8(bitsPerPixel); writer.u8(depth); writer.u8(bigEndian ? 1 : 0); writer.u8(trueColour ? 1 : 0)
    writer.u16(redMax); writer.u16(greenMax); writer.u16(blueMax)
    writer.u8(redShift); writer.u8(greenShift); writer.u8(blueShift)
    writer.pad(3)
    return writer.bytes
  }

  public static func decode(_ bytes: [UInt8]) throws -> RFBPixelFormat {
    guard bytes.count == 16 else { throw RFBError.malformed("pixel format is \(bytes.count) bytes") }
    func u16(_ index: Int) -> UInt16 { UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]) }
    return RFBPixelFormat(
      bitsPerPixel: bytes[0], depth: bytes[1], bigEndian: bytes[2] != 0, trueColour: bytes[3] != 0,
      redMax: u16(4), greenMax: u16(6), blueMax: u16(8), redShift: bytes[10], greenShift: bytes[11],
      blueShift: bytes[12])
  }
}

public enum RFBEncoding: Int32, Sendable, CaseIterable {
  case raw = 0
  case copyRect = 1
  case tight = 7
  case zrle = 16
  case desktopSize = -223
  case cursor = -239
  case pointerPosition = -232
  case fence = -312
  case extendedDesktopSize = -308
  case extendedClipboard = -1_063_131_698
  case continuousUpdates = -313

  public static let supported: [RFBEncoding] = [
    .tight, .zrle, .copyRect, .raw, .desktopSize, .cursor, .pointerPosition, .fence, .continuousUpdates,
    .extendedDesktopSize, .extendedClipboard,
  ]
}

public struct RFBRectangle: Sendable, Equatable, Hashable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int
  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
  public var maxX: Int { x + width }
  public var maxY: Int { y + height }
  public var isEmpty: Bool { width <= 0 || height <= 0 }
}

public struct RFBServerParameters: Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var pixelFormat: RFBPixelFormat
  public var name: String
  public init(width: Int, height: Int, pixelFormat: RFBPixelFormat, name: String) {
    self.width = width; self.height = height; self.pixelFormat = pixelFormat; self.name = name
  }
}

public enum RFBServerEvent: Sendable, Equatable {
  case bell
  case serverCutText(String)
  case continuousUpdates(Bool)
  case roundTrip(Duration)
  case extendedClipboard(RFBExtendedClipboard.Message)
}

public struct RFBUpdate: Sendable, Equatable {
  public var rectangles: [RFBRectangle]
  public var resized: Bool
  public var cursor: RFBCursorShape?
  public var pointer: RFBPoint?
  public var desktopSize: RFBDesktopSizeResult?
  public var byteCount = 0
  public var latency: Duration?
  public var linkBytes = 0
  public var linkDuration: Duration = .zero
  public var jpegRectangles = 0
  public init(rectangles: [RFBRectangle], resized: Bool) { self.rectangles = rectangles; self.resized = resized }

  public static func == (lhs: RFBUpdate, rhs: RFBUpdate) -> Bool {
    lhs.rectangles == rhs.rectangles && lhs.resized == rhs.resized && lhs.cursor == rhs.cursor
      && lhs.pointer == rhs.pointer && lhs.desktopSize == rhs.desktopSize
  }
}

public struct RFBScreen: Sendable, Equatable, Hashable {
  public var id: UInt32
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int
  public var flags: UInt32
  public init(id: UInt32, x: Int, y: Int, width: Int, height: Int, flags: UInt32 = 0) {
    self.id = id; self.x = x; self.y = y; self.width = width; self.height = height; self.flags = flags
  }
}

public struct RFBDesktopSizeResult: Sendable, Equatable {
  public enum Reason: Int, Sendable { case server = 0, thisClient = 1, otherClient = 2 }
  public enum Status: Int, Sendable { case ok = 0, prohibited = 1, outOfResources = 2, invalidLayout = 3 }
  public var reason: Reason
  public var status: Status
  public var width: Int
  public var height: Int
  public var screens: [RFBScreen]
  public init(reason: Reason, status: Status, width: Int, height: Int, screens: [RFBScreen]) {
    self.reason = reason; self.status = status; self.width = width; self.height = height; self.screens = screens
  }
}

public struct RFBPoint: Sendable, Equatable, Hashable {
  public var x: Int
  public var y: Int
  public init(x: Int, y: Int) { self.x = x; self.y = y }
}
