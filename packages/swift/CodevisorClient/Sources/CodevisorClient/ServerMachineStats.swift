import Foundation

public struct ServerMachineStats: Decodable, Equatable, Sendable {
  public struct Usage: Decodable, Equatable, Sendable {
    public var usedBytes: Double
    public var totalBytes: Double
  }

  public struct CpuSample: Decodable, Equatable, Sendable {
    public var at: String
    public var usedPercent: Double
  }

  public struct Cpu: Decodable, Equatable, Sendable {
    public var cores: Int
    public var usedPercent: Double?
    public var history: [CpuSample]
  }

  public var sampledAt: String
  public var uptimeSeconds: Double
  public var cpu: Cpu
  public var memory: Usage
  public var disk: Usage?
}
