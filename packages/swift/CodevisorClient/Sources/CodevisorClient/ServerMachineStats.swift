import Foundation

public struct ServerMachineStats: Decodable, Equatable, Sendable {
  public struct Usage: Decodable, Equatable, Sendable {
    public var usedBytes: Double
    public var totalBytes: Double
  }

  public struct LoadSample: Decodable, Equatable, Sendable {
    public var at: String
    public var usedPercent: Double
  }

  public struct Cpu: Decodable, Equatable, Sendable {
    public var model: String?
    public var cores: Int
    public var usedPercent: Double?
    public var history: [LoadSample]
  }

  public struct Gpu: Decodable, Equatable, Sendable {
    public var model: String?
    public var cores: Int?
    public var usedPercent: Double?
    public var history: [LoadSample]
  }

  public var sampledAt: String
  public var uptimeSeconds: Double
  public var cpu: Cpu
  public var gpu: Gpu?
  public var memory: Usage
  public var disk: Usage?
}
