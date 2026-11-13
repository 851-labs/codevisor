import CodevisorClient
import CodevisorCore

public enum ProtectedFolderPermission {
  @MainActor
  public static func check(_ folder: ServerFirstRunFolder) -> FirstRunFolderPermission {
    if TCCPreflight.isAllowed("kTCCServiceSystemPolicyAllFiles") { return .allowed }
    return combined(services(for: folder).map(TCCPreflight.status(of:)))
  }

  private static let homeFolderServices = [
    "desktop": "kTCCServiceSystemPolicyDesktopFolder",
    "documents": "kTCCServiceSystemPolicyDocumentsFolder",
    "downloads": "kTCCServiceSystemPolicyDownloadsFolder",
  ]

  private static let driveServices = [
    "kTCCServiceSystemPolicyRemovableVolumes",
    "kTCCServiceSystemPolicyNetworkVolumes",
  ]

  private static func services(for folder: ServerFirstRunFolder) -> [String] {
    if let service = homeFolderServices[folder.id] { return [service] }
    return folder.id.hasPrefix("volume:") ? driveServices : []
  }

  private static func combined(_ statuses: [TCCPreflight.Status]) -> FirstRunFolderPermission {
    guard let first = statuses.first, statuses.allSatisfy({ $0 == first }) else { return .undetermined }
    switch first {
    case .allowed: return .allowed
    case .denied: return .denied
    case .undetermined: return .undetermined
    }
  }
}
