public struct BenchCell: Codable, Hashable, Sendable {
  public var system: BenchSystem
  public var scene: String
  public var resolution: String
  public var network: String

  public init(system: BenchSystem, scene: String, resolution: String, network: String) {
    self.system = system
    self.scene = scene
    self.resolution = resolution
    self.network = network
  }

  public init(_ result: BenchResult) {
    self.init(system: result.system, scene: result.scene, resolution: result.resolution, network: result.network)
  }
}
