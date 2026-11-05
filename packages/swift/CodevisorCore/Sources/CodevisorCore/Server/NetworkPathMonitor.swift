import Foundation
import Network
import Observation

@MainActor
@Observable
public final class NetworkPathMonitor {
  public private(set) var isOnline = true
  public private(set) var recoveryToken = 0
  @ObservationIgnored var onOnlineChange: ((Bool) -> Void)?
  @ObservationIgnored private let monitor = NWPathMonitor()
  @ObservationIgnored private var signature: String?

  public init() {}

  public func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      let reading = NetworkPathReading(path)
      Task { @MainActor in self?.apply(reading) }
    }
    monitor.start(queue: DispatchQueue(label: "dev.codevisor.network-path"))
  }

  isolated deinit {
    monitor.cancel()
  }

  func apply(_ reading: NetworkPathReading) {
    let previous = signature
    signature = reading.signature
    if isOnline != reading.isSatisfied {
      isOnline = reading.isSatisfied
      onOnlineChange?(isOnline)
    }
    guard previous != nil, previous != reading.signature, reading.isSatisfied else { return }

    recoveryToken &+= 1
  }
}

nonisolated struct NetworkPathReading: Sendable, Equatable {
  let isSatisfied: Bool
  let signature: String

  init(isSatisfied: Bool, signature: String) {
    self.isSatisfied = isSatisfied
    self.signature = signature
  }

  init(_ path: NWPath) {
    let interfaces: [(NWInterface.InterfaceType, String)] = [
      (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "ethernet"),
    ]
    let flags = [path.isExpensive ? "expensive" : "", path.isConstrained ? "constrained" : ""]
    self.init(
      isSatisfied: path.status == .satisfied,
      signature: ([String(describing: path.status)] + interfaces.map { path.usesInterfaceType($0.0) ? $0.1 : "" }
        + flags).joined(separator: ":")
    )
  }
}
