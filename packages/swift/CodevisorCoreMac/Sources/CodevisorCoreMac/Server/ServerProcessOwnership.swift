import Foundation

enum ServerProcessOwnership {
  struct Owner: Decodable {
    var pid: Int32
    var bootId: String
    var databasePath: String
  }

  static func owner(databasePath: String) -> Owner? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: databasePath + ".server-owner.json")),
      let owner = try? JSONDecoder().decode(Owner.self, from: data),
      owner.pid > 1, owner.databasePath == databasePath
    else { return nil }
    return owner
  }

  static func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  static func hasStopped(port: Int, databasePath: String, previousOwner: Owner?) async -> Bool {
    if let previousOwner, isAlive(previousOwner.pid) { return false }
    if let current = owner(databasePath: databasePath), isAlive(current.pid) { return false }
    // A killed process can leave proper-lockfile's heartbeat directory. It
    // becomes acquirable after five seconds; never delete an active lease.
    if let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath + ".lock"),
      let modified = attributes[.modificationDate] as? Date,
      Date().timeIntervalSince(modified) <= 5
    {
      return false
    }
    do {
      let result = try await ProcessCommandRunner().run(
        executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
        arguments: ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"],
        environment: nil, timeout: .seconds(2)
      )
      return result.exitCode == 1 && result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch { return false }
  }

  static func terminate(_ expected: Owner?, databasePath: String) async {
    guard let expected, let current = owner(databasePath: databasePath),
      expected.pid == current.pid, expected.bootId == current.bootId,
      current.pid != ProcessInfo.processInfo.processIdentifier, isAlive(current.pid)
    else { return }
    // PID reuse or stale metadata must never signal an unrelated process.
    guard
      let result = try? await ProcessCommandRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-p", String(current.pid), "-o", "comm="],
        environment: nil, timeout: .seconds(2)
      ), result.exitCode == 0,
      result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "codevisor-server"
    else { return }
    kill(current.pid, SIGTERM)
  }
}
