import Foundation

public enum DiagnosticIssueName: String, Sendable, CaseIterable {
  case corruptPersistedData = "corrupt_persisted_data"
  case dataDirectoryUnavailable = "data_directory_unavailable"
  case persistenceWriteFailed = "persistence_write_failed"
  case terminalOpenFailed = "terminal_open_failed"
  case appRelaunchFailed = "app_relaunch_failed"

  public var component: String {
    switch self {
    case .corruptPersistedData, .dataDirectoryUnavailable, .persistenceWriteFailed:
      "persistence"
    case .terminalOpenFailed:
      "terminal"
    case .appRelaunchFailed:
      "updates"
    }
  }
}

@MainActor
public protocol DiagnosticsSink: AnyObject {
  func setEnabled(_ enabled: Bool)
  func capture(_ issue: DiagnosticIssueName)
  func noteSyncEvent(machineIsLocal: Bool, kind: String)
}

@MainActor
public enum Diagnostics {
  public static var sink: (any DiagnosticsSink)?

  public static func setEnabled(_ enabled: Bool) {
    sink?.setEnabled(enabled)
  }

  public static func capture(_ issue: DiagnosticIssueName) {
    sink?.capture(issue)
  }

  public static func noteSyncEvent(machineIsLocal: Bool, kind: String) {
    sink?.noteSyncEvent(machineIsLocal: machineIsLocal, kind: kind)
  }
}
