import Foundation

enum ScreenSharingPeers {
  private static let screenSharingPort = ".5900"

  @concurrent
  static func established() async throws -> [String] {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-an", "-p", "tcp"]
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Array(Set(output.split(separator: "\n").compactMap(peer))).sorted()
  }

  private static func peer(_ line: Substring) -> String? {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 6, fields[5] == "ESTABLISHED", fields[3].hasSuffix(screenSharingPort) else { return nil }
    guard let dot = fields[4].lastIndex(of: ".") else { return nil }

    return PeerAddress.normalized(String(fields[4][..<dot]))
  }
}
