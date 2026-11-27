import CodevisorClient
import Foundation

public enum MachineDesktopWords {
  public static let setupCommand = "codevisor desktop setup"
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

  public static func notRunning(_ status: ServerDesktopStatus, on machine: String) -> String {
    "The desktop on \(machine) isn't running: \(sentence(from: status.problem ?? "no reason found"))"
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

  public static func stillMissing(_ status: ServerDesktopStatus) -> String {
    "Still missing after the install: \(status.missing.joined(separator: ", "))."
  }

  public static func notSeen(on machine: String) -> String {
    "The desktop on \(machine) started, but it isn't shared with Codevisor yet."
  }

  public static func runInATerminal(_ command: String) -> String {
    "Run this in a terminal there: \(command)"
  }

  public static func sentence(from text: String) -> String {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let first = lines.first else { return text }
    guard first.hasSuffix(":"), let last = lines.last, last != first else { return first }

    return "\(first) \(last)"
  }

  public static func sentence(from error: any Error) -> String {
    sentence(from: error.localizedDescription)
  }
}
