import Foundation
import Testing
@testable import ScreenSharing

struct RFBHandshakeTests {
  static let serverInit: [UInt8] = u16(800) + u16(600) + RFBPixelFormat.bgra32.encoded + u32(4) + Array("Desk".utf8)
  static let parameters = RFBServerParameters(width: 800, height: 600, pixelFormat: .bgra32, name: "Desk")

  private func perform(
    _ bytes: [UInt8], password: String?, chunk: Int = 3
  ) async throws -> (RFBHandshake.Outcome, [UInt8]) {
    let transport = ScriptedTransport(bytes, chunk: chunk)
    let outcome = try await RFBHandshake.perform(
      stream: RFBInputStream(transport: transport), transport: transport, password: password)
    return (outcome, transport.written)
  }

  @Test func version38WithVNCAuthentication() async throws {
    let challenge: [UInt8] = Array(0..<16)
    let script = Array("RFB 003.008\n".utf8) + [2, 30, 2] + challenge + u32(0) + Self.serverInit
    let (outcome, written) = try await perform(script, password: "secret")
    #expect(outcome == RFBHandshake.Outcome(version: .v3_8, security: .vncAuthentication, parameters: Self.parameters))
    #expect(
      written == Array("RFB 003.008\n".utf8) + [2]
        + RFBVNCAuthentication.response(challenge: challenge, password: "secret") + [1])
  }

  @Test func appleVersionNegotiatesDownTo38() async throws {
    let script = Array("RFB 003.889\n".utf8) + [1, 1] + u32(0) + Self.serverInit
    let (outcome, written) = try await perform(script, password: nil)
    #expect(outcome.version == .v3_8)
    #expect(outcome.security == .none)
    #expect(Array(written.prefix(12)) == Array("RFB 003.008\n".utf8))
  }

  @Test func version37NoneHasNoSecurityResult() async throws {
    let script = Array("RFB 003.007\n".utf8) + [1, 1] + Self.serverInit
    let (outcome, written) = try await perform(script, password: "unused")
    #expect(outcome.version == .v3_7)
    #expect(outcome.security == .none)
    #expect(written == Array("RFB 003.007\n".utf8) + [1, 1])
  }

  @Test func version33ServerDecidesTheSecurityType() async throws {
    let challenge = [UInt8](repeating: 7, count: 16)
    let script = Array("RFB 003.003\n".utf8) + u32(2) + challenge + u32(0) + Self.serverInit
    let (outcome, written) = try await perform(script, password: "pw")
    #expect(outcome.version == .v3_3)
    #expect(outcome.security == .vncAuthentication)
    #expect(
      written == Array("RFB 003.003\n".utf8) + RFBVNCAuthentication.response(challenge: challenge, password: "pw") + [1]
    )
  }

  @Test func preferVNCAuthenticationOnlyWhenAPasswordIsGiven() async throws {
    let script = Array("RFB 003.008\n".utf8) + [2, 2, 1] + u32(0) + Self.serverInit
    let (outcome, _) = try await perform(script, password: nil)
    #expect(outcome.security == .none)
  }

  @Test func rejectedPasswordReportsTheServersReason() async throws {
    let script = Array("RFB 003.008\n".utf8) + [1, 2] + [UInt8](0..<16) + u32(1) + u32(9) + Array("Bad pass!".utf8)
    await #expect(throws: RFBError.authenticationFailed("Bad pass!")) { try await perform(script, password: "x") }
  }

  @Test func rejectedPasswordOn37HasAGenericMessage() async throws {
    let script = Array("RFB 003.007\n".utf8) + [1, 2] + [UInt8](0..<16) + u32(1)
    await #expect(throws: RFBError.authenticationFailed("The VNC server rejected the password.")) {
      try await perform(script, password: "x")
    }
  }

  @Test func passwordRequiredButMissing() async throws {
    let script = Array("RFB 003.008\n".utf8) + [1, 2]
    await #expect(throws: RFBError.authenticationFailed("This VNC server requires a password.")) {
      try await perform(script, password: nil)
    }
  }

  @Test func appleRemoteDesktopOnlyExplainsTheSetting() async throws {
    let script = Array("RFB 003.889\n".utf8) + [2, 30, 35]
    await #expect(throws: RFBError.securityUnsupported([30, 35])) { try await perform(script, password: "x") }
    #expect(
      RFBError.securityUnsupported([30, 35]).errorDescription?.contains("VNC viewers may control screen") == true)
  }

  @Test func serverRefusalCarriesItsReason() async throws {
    let script = Array("RFB 003.008\n".utf8) + [0] + u32(4) + Array("Full".utf8)
    await #expect(throws: RFBError.authenticationFailed("Full")) { try await perform(script, password: nil) }
  }

  @Test func nonRFBGreetingIsAMismatch() async throws {
    await #expect(throws: RFBError.protocolMismatch("no RFB greeting")) {
      try await perform(Array("SSH-2.0-OpenSSH\n".utf8), password: nil)
    }
  }

  @Test func closedBeforeServerInitIsConnectionClosed() async throws {
    let script = Array("RFB 003.008\n".utf8) + [1, 1] + u32(0) + u16(800)
    await #expect(throws: RFBError.connectionClosed) { try await perform(script, password: nil) }
  }
}
