import Foundation

/// ProtocolVersion, security negotiation, authentication, ClientInit and
/// ServerInit — the part of a connection before any framebuffer traffic.
public enum RFBHandshake {
  public struct Outcome: Sendable, Equatable {
    public var version: RFBProtocolVersion
    public var security: RFBSecurityType
    public var parameters: RFBServerParameters
  }

  /// Negotiates the newest of 3.3/3.7/3.8 the server supports (Apple's
  /// 3.889 counts as 3.8), picks VNC Authentication when a password is
  /// given and offered, otherwise None, and returns the ServerInit.
  public static func perform(
    stream: RFBInputStream, transport: any RFBTransport, password: String?, shared: Bool = true
  ) async throws -> Outcome {
    let serverVersion = RFBProtocolVersion.parse(try await stream.bytes(12))
    guard let serverVersion, serverVersion >= .v3_3 else {
      throw RFBError.protocolMismatch(
        serverVersion.map { "unsupported version \($0.major).\($0.minor)" } ?? "no RFB greeting")
    }
    let version: RFBProtocolVersion = serverVersion >= .v3_8 ? .v3_8 : (serverVersion >= .v3_7 ? .v3_7 : .v3_3)
    try await transport.write(version.encoded)

    let security: RFBSecurityType
    if version == .v3_3 {
      let type = try await stream.u32()
      guard type != 0 else { throw RFBError.authenticationFailed(try await reason(stream)) }
      guard let chosen = RFBSecurityType(rawValue: UInt8(clamping: type)), chosen != .appleRemoteDesktop else {
        throw RFBError.securityUnsupported([UInt8(clamping: type)])
      }
      security = chosen
    } else {
      let count = Int(try await stream.u8())
      guard count > 0 else { throw RFBError.authenticationFailed(try await reason(stream)) }
      let offered = try await stream.bytes(count)
      if password != nil, offered.contains(RFBSecurityType.vncAuthentication.rawValue) {
        security = .vncAuthentication
      } else if offered.contains(RFBSecurityType.none.rawValue) {
        security = .none
      } else if offered.contains(RFBSecurityType.vncAuthentication.rawValue) {
        throw RFBError.authenticationFailed("This VNC server requires a password.")
      } else {
        throw RFBError.securityUnsupported(offered)
      }
      try await transport.write([security.rawValue])
    }

    switch security {
    case .vncAuthentication:
      guard let password else { throw RFBError.authenticationFailed("This VNC server requires a password.") }
      let challenge = try await stream.bytes(16)
      try await transport.write(RFBVNCAuthentication.response(challenge: challenge, password: password))
      try await securityResult(stream, version: version)
    case .none:
      if version == .v3_8 { try await securityResult(stream, version: version) }
    case .appleRemoteDesktop:
      throw RFBError.securityUnsupported([security.rawValue])
    }

    try await transport.write([shared ? 1 : 0])
    let width = Int(try await stream.u16()), height = Int(try await stream.u16())
    let format = try RFBPixelFormat.decode(try await stream.bytes(16))
    let name = String(decoding: try await stream.bytes(Int(try await stream.u32())), as: UTF8.self)
    return Outcome(
      version: version, security: security,
      parameters: RFBServerParameters(width: width, height: height, pixelFormat: format, name: name))
  }

  private static func securityResult(_ stream: RFBInputStream, version: RFBProtocolVersion) async throws {
    switch try await stream.u32() {
    case 0: return
    case 1:
      throw RFBError.authenticationFailed(
        version == .v3_8 ? try await reason(stream) : "The VNC server rejected the password.")
    case 2: throw RFBError.authenticationFailed("Too many failed sign-in attempts. Try again later.")
    case let status: throw RFBError.malformed("security result \(status)")
    }
  }

  private static func reason(_ stream: RFBInputStream) async throws -> String {
    let length = Int(try await stream.u32())
    guard length <= 4096 else { throw RFBError.malformed("reason of \(length) bytes") }
    let text = String(decoding: try await stream.bytes(length), as: UTF8.self)
    return text.isEmpty ? "The VNC server refused the connection." : text
  }
}
