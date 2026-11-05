import Foundation
public enum NetBatchedUDP {
  public static let environmentKey = "CODEVISOR_NET_BATCHED_UDP"

  public static func configured(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment[environmentKey] == "1"
  }
}
