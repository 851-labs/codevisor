import Foundation

/// SDP edits for screen-sharing media over the Codevisor tunnel
/// (docs/plans/codevisor-tunnel.md). The viewer's WebRTC stack keeps its own
/// ICE, DTLS and RTP; it just sees one remote candidate — the local end of a
/// tunnel media flow — instead of the host's real addresses. The machine
/// forwards that flow to the host's own candidate, so ICE completes over the
/// tunnel (the host learns the forwarder as a peer-reflexive candidate).
public enum ScreenSharingTunnelSDP {
  /// The first IPv4 host candidate address in an SDP (the viewer's own LAN
  /// address, from its offer), skipping loopback and link-local. The tunnel
  /// flow's local socket listens on every interface, so naming it with this
  /// address keeps WebRTC on an ordinary LAN path (it ignores loopback).
  public static func localIPv4(inOffer offer: String) -> String? {
    for line in offer.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: " ")
      guard line.hasPrefix("a=candidate:"), fields.count >= 8, fields[2].lowercased() == "udp",
        fields[7] == "host"
      else { continue }
      let ip = String(fields[4])
      let octets = ip.split(separator: ".")
      guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }), !ip.hasPrefix("127."),
        !ip.hasPrefix("169.254.")
      else { continue }
      return ip
    }
    return nil
  }

  /// The answer with every remote candidate (and end-of-candidates marker)
  /// replaced by a single host candidate for `address:port`, inserted once
  /// per media section, after its `a=mid` line.
  public static func answer(_ answer: String, routedTo address: String, port: UInt16) -> String {
    let newline = answer.contains("\r\n") ? "\r\n" : "\n"
    let candidate = "a=candidate:tunnel 1 udp 2130706431 \(address) \(port) typ host"
    var lines: [String] = []
    for line in answer.components(separatedBy: newline) {
      if line.hasPrefix("a=candidate:") || line == "a=end-of-candidates" { continue }
      lines.append(line)
      if line.hasPrefix("a=mid:") {
        lines.append(candidate)
        lines.append("a=end-of-candidates")
      }
    }
    return lines.joined(separator: newline)
  }
}
