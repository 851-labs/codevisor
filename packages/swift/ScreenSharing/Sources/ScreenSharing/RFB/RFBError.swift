import Foundation

/// Every failure is terminal: RFB has no resynchronisation, so the session
/// that hits one closes the transport and reports the message.
public enum RFBError: Error, LocalizedError, Sendable, Equatable {
  case connectionClosed
  case protocolMismatch(String)
  /// The server offered only security types this client does not implement.
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

  /// The twelve-byte ProtocolVersion message, "RFB xxx.yyy\n".
  public var encoded: [UInt8] { Array(description.utf8) }
  public var description: String {
    "RFB " + String(format: "%03d.%03d", major, minor) + "\n"
  }
  public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor) < (rhs.major, rhs.minor) }

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

  /// The one format this client renders: little-endian 0x00RRGGBB, so the bytes
  /// in memory are B, G, R, X — `kCVPixelFormatType_32BGRA` as-is.
  public static let bgra32 = RFBPixelFormat(
    bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true, redMax: 255, greenMax: 255, blueMax: 255,
    redShift: 16, greenShift: 8, blueShift: 0)

  public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

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
  /// Tight: fill, JPEG and zlib rectangles with palette/gradient filters (851-2313).
  case tight = 7
  case zrle = 16
  /// Pseudo-encoding: the framebuffer changed size.
  case desktopSize = -223
  /// Pseudo-encoding: the pointer's shape, drawn by the client (the server
  /// stops painting it into the framebuffer).
  case cursor = -239
  /// Pseudo-encoding: the server moved the pointer (another client, an
  /// agent, the desktop itself); the rectangle's x and y are its position.
  case pointerPosition = -232
  /// Pseudo-encoding: the client answers Fence requests (and can send its own).
  case fence = -312
  /// Pseudo-encoding: the framebuffer's size and screen layout, and the
  /// result of the client's SetDesktopSize (851-2314).
  case extendedDesktopSize = -308
  /// Pseudo-encoding 0xC0A1E5CE: UTF-8 clipboard (851-2316).
  case extendedClipboard = -1_063_131_698
  /// Pseudo-encoding: the client can take pushed updates without requesting each one.
  case continuousUpdates = -313

  /// What this client advertises, in preference order.
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

/// The ServerInit message: the framebuffer the server offers.
public struct RFBServerParameters: Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var pixelFormat: RFBPixelFormat
  public var name: String
  public init(width: Int, height: Int, pixelFormat: RFBPixelFormat, name: String) {
    self.width = width; self.height = height; self.pixelFormat = pixelFormat; self.name = name
  }
}

/// Server messages other than framebuffer updates.
public enum RFBServerEvent: Sendable, Equatable {
  case bell
  case serverCutText(String)
  /// The server confirmed continuous updates and the client turned them on (true), or they ended (false).
  case continuousUpdates(Bool)
  /// The round trip of one of the client's own fences.
  case roundTrip(Duration)
  /// An Extended Clipboard message (caps, request, notify, provide, peek).
  case extendedClipboard(RFBExtendedClipboard.Message)
}

/// One applied FramebufferUpdate. Equality compares content (rectangles,
/// resize, cursor and pointer), not the measurements.
public struct RFBUpdate: Sendable, Equatable {
  public var rectangles: [RFBRectangle]
  public var resized: Bool
  /// The last cursor shape the update carried, if any.
  public var cursor: RFBCursorShape?
  /// The last server-side pointer position the update carried, if any.
  public var pointer: RFBPoint?
  /// The last ExtendedDesktopSize the update carried: the server's layout, or its answer to SetDesktopSize.
  public var desktopSize: RFBDesktopSizeResult?
  /// The message's size on the wire, header included.
  public var byteCount = 0
  /// From sending the request this update answers to applying the update;
  /// nil for an update the server pushed (continuous updates).
  public var latency: Duration?
  /// From the update's header to its last rectangle applied (includes decoding and local buffering).
  public var transferDuration: Duration?
  /// The link's share of this update (851-2331): bytes that arrived while the
  /// reader waited for the network, and that wait. Their ratio is the link
  /// rate; zero when the update was already buffered locally.
  public var linkBytes = 0
  public var linkDuration: Duration = .zero
  /// Tight rectangles that arrived as JPEG.
  public var jpegRectangles = 0
  public init(rectangles: [RFBRectangle], resized: Bool) { self.rectangles = rectangles; self.resized = resized }

  public static func == (lhs: RFBUpdate, rhs: RFBUpdate) -> Bool {
    lhs.rectangles == rhs.rectangles && lhs.resized == rhs.resized && lhs.cursor == rhs.cursor
      && lhs.pointer == rhs.pointer && lhs.desktopSize == rhs.desktopSize
  }
}

/// One screen of an ExtendedDesktopSize layout, in framebuffer pixels.
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

/// An ExtendedDesktopSize rectangle: why the size changed (or didn't), and the layout.
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

/// A position in framebuffer pixels.
public struct RFBPoint: Sendable, Equatable, Hashable {
  public var x: Int
  public var y: Int
  public init(x: Int, y: Int) { self.x = x; self.y = y }
}
