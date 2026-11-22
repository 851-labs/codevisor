import CodevisorCore

public enum TrackedPermission: String, Sendable {
  case accessibility
  case screenRecording = "screen_recording"
  case fullDiskAccess = "full_disk_access"
  case notifications
}

@MainActor
public enum PermissionAnalytics {
  public static func requested(_ permission: TrackedPermission) {
    Analytics.capture(.permissionRequested, properties: ["permission": .string(permission.rawValue)])
  }

  public static func granted(_ permission: TrackedPermission) {
    Analytics.capture(.permissionGranted, properties: ["permission": .string(permission.rawValue)])
  }
}

@MainActor
final class PermissionRequestTracker {
  private var awaitingGrant: Set<TrackedPermission> = []

  func requested(_ permission: TrackedPermission) {
    guard awaitingGrant.insert(permission).inserted else { return }
    PermissionAnalytics.requested(permission)
  }

  func observe(_ permission: TrackedPermission, isGranted: Bool) {
    guard isGranted, awaitingGrant.remove(permission) != nil else { return }
    PermissionAnalytics.granted(permission)
  }
}
