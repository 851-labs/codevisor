import Foundation

public enum ScreenSharingTunnelSDP {
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
