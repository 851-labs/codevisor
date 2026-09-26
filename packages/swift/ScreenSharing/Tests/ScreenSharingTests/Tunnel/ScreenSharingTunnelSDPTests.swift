import Foundation
import Testing

@testable import ScreenSharing

/// Media over the Codevisor tunnel only changes which remote candidate the
/// viewer's WebRTC dials; these pin that rewrite.
struct ScreenSharingTunnelSDPTests {
  private let offer = [
    "v=0",
    "m=video 9 UDP/TLS/RTP/SAVPF 96",
    "a=candidate:1 1 udp 2122260223 127.0.0.1 50001 typ host generation 0",
    "a=candidate:2 1 udp 2122194687 169.254.7.1 50002 typ host generation 0",
    "a=candidate:3 1 tcp 1518280447 10.0.0.9 9 typ host tcptype active",
    "a=candidate:4 1 udp 2122129151 10.0.0.9 50004 typ host generation 0",
  ].joined(separator: "\r\n")

  @Test("The viewer's own LAN address comes from its offer")
  func localAddress() {
    #expect(ScreenSharingTunnelSDP.localIPv4(inOffer: offer) == "10.0.0.9")
    #expect(ScreenSharingTunnelSDP.localIPv4(inOffer: "v=0\r\nm=video 9 UDP 96") == nil)
    #expect(
      ScreenSharingTunnelSDP.localIPv4(inOffer: "a=candidate:1 1 udp 1 fe80::1 5 typ host") == nil)
  }

  @Test("Every remote candidate is replaced by the tunnel flow, once per media section")
  func answerRewrite() {
    let answer = [
      "v=0",
      "m=video 9 UDP/TLS/RTP/SAVPF 96",
      "a=mid:0",
      "a=candidate:1 1 udp 2122260223 192.168.1.20 50004 typ host",
      "a=candidate:2 1 udp 1686052607 203.0.113.9 61000 typ srflx raddr 192.168.1.20 rport 50004",
      "a=end-of-candidates",
      "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
      "a=mid:1",
      "",
    ].joined(separator: "\r\n")
    let rewritten = ScreenSharingTunnelSDP.answer(answer, routedTo: "10.0.0.9", port: 41_000)
    let tunnel = "a=candidate:tunnel 1 udp 2130706431 10.0.0.9 41000 typ host"
    #expect(
      rewritten
        == [
          "v=0",
          "m=video 9 UDP/TLS/RTP/SAVPF 96",
          "a=mid:0",
          tunnel,
          "a=end-of-candidates",
          "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
          "a=mid:1",
          tunnel,
          "a=end-of-candidates",
          "",
        ].joined(separator: "\r\n"))
  }
}
