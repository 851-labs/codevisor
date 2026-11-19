import AppKit

struct QuitApp: Encodable, Equatable {
  let name: String
  let bundleId: String
  let path: String
  let pid: pid_t
  let asked: Bool

  init(_ app: NSRunningApplication, asked: Bool) {
    name = app.localizedName ?? ""
    bundleId = app.bundleIdentifier ?? ""
    path = app.bundleURL?.path ?? ""
    pid = app.processIdentifier
    self.asked = asked
  }

  var isRunning: Bool {
    kill(pid, 0) == 0
  }
}
