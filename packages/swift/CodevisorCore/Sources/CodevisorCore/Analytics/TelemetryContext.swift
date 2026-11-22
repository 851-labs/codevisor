import Foundation

public struct TelemetryContext: Sendable, Equatable {
  public static let flagPrefix = "flag_"

  public let enabledFlags: [String]
  public let updateChannel: String

  public init(enabledFlags: some Sequence<String>, updateChannel: String) {
    self.enabledFlags = Array(Set(enabledFlags)).sorted()
    self.updateChannel = updateChannel
  }

  public var tags: [String: String] {
    var tags = ["update_channel": updateChannel, "feature_flags": enabledFlags.joined(separator: ",")]
    for flag in enabledFlags {
      tags[Self.flagPrefix + flag] = "true"
    }
    return tags
  }
}
