import CodevisorClient
import Foundation

public enum MachineDesktopWords {
  public static let setupCommand = "codevisor desktop setup"
  public static let setupTerminalName = "Desktop setup"
  public static let noDesktop = "No desktop on this machine yet."
  public static let setUpBefore = "This machine's desktop was set up for an older version of Codevisor."
  public static let installing = "Installing Xfce and TigerVNC…"
  public static let removingOld = "Removing the older desktop…"
  public static let starting = "Starting the desktop…"
  public static let removing = "Removing the desktop…"
  public static let unsharing = "Stopping sharing the desktop…"

  public static func waitingForAnswer(on machine: String) -> String {
    "Waiting for your answer about the desktop on \(machine)."
  }

  public static func checking(_ machine: String) -> String { "Checking \(machine)…" }

  public static func updateNeeded(on machine: String) -> String {
    "Update Codevisor on \(machine) to set up a desktop."
  }

  public static func notRunning(on machine: String) -> String { "The desktop on \(machine) isn't running." }

  public static func notChecked(on machine: String) -> String { "Couldn't check the desktop on \(machine)." }

  public static func notRemoved(on machine: String, unsharing: Bool) -> String {
    unsharing ? "Couldn't stop sharing the desktop on \(machine)." : "Couldn't remove the desktop on \(machine)."
  }

  public static func notStarted(on machine: String) -> String { "The desktop on \(machine) didn't start." }

  public static func notSetUp(on machine: String) -> String { "Setting up the desktop on \(machine) didn't work." }

  public static func notInstalled(on machine: String) -> String {
    "Installing Xfce and TigerVNC on \(machine) didn't work."
  }

  public static func administratorNeeded(for what: String, on machine: String) -> String {
    "\(what) needs an administrator on \(machine)."
  }

  public static func oldDesktopStillRuns(on machine: String) -> String {
    "The older desktop on \(machine) is still running. Stop it, then try again."
  }

  public static func cannotInstall(_ status: ServerDesktopStatus, on machine: String) -> String {
    "Codevisor doesn't know how to install packages on \(status.system). Install these on \(machine), then try again: \(status.missing.joined(separator: ", "))."
  }

  public static func stillMissing(on machine: String) -> String {
    "Xfce and TigerVNC are still missing on \(machine) after the install."
  }

  public static func notSeen(on machine: String) -> String {
    "The desktop on \(machine) started, but it isn't shared with Codevisor yet."
  }

  public static func runInATerminal(_ command: String) -> String {
    "Run this in a terminal there: \(command)"
  }
}
