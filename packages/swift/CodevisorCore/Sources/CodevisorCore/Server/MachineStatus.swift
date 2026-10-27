import Foundation

public struct MachineStatus: Sendable, Equatable {
  public var isReachable: Bool
  public var label: String
  public var cloudDeviceId: String?
  public var serverId: String?
  public var features: Set<String>
  public var maxUploadBytes: Int?

  public init(
    isReachable: Bool,
    label: String,
    cloudDeviceId: String? = nil,
    serverId: String? = nil,
    features: Set<String> = [],
    maxUploadBytes: Int? = nil
  ) {
    self.isReachable = isReachable
    self.label = label
    self.cloudDeviceId = cloudDeviceId
    self.serverId = serverId
    self.features = features
    self.maxUploadBytes = maxUploadBytes
  }

  public static let legacyUploadLimitBytes = 32 * 1024 * 1024

  public var uploadLimitBytes: Int { maxUploadBytes ?? Self.legacyUploadLimitBytes }

  public var supportsScreenSharing: Bool { features.contains("screen-sharing-v1") }
  public var supportsComputerUseStreaming: Bool { features.contains("computer-use-stream-v1") }
  public var supportsLivePreview: Bool { features.contains("live-preview-v1") }
  public var supportsSimulator: Bool { features.contains("simulator-v1") }
  public var supportsBots: Bool { features.contains("bots-v1") }
  public var supportsBotProjectChanges: Bool { features.contains("bot-projects-v1") }
  public var supportsPlugins: Bool { features.contains("plugins-v2") }
}

public func codevisorMachineIsThisMac(
  _ machineId: String,
  statusByMachineId: [String: MachineStatus]
) -> Bool {
  if machineId == CodevisorMachine.local.id { return true }
  guard let local = statusByMachineId[CodevisorMachine.local.id]?.serverId,
    let other = statusByMachineId[machineId]?.serverId
  else { return false }
  return local == other
}
