import CodevisorUI
import Foundation

actor ChromiumAutomationHub {
  nonisolated enum TargetEvent: Sendable {
    case targetCreated(ChromiumTargetInfo, machineId: String)
    case targetDestroyed(String, machineId: String)
  }
  nonisolated var unownedExecutor: UnownedSerialExecutor { ChromiumAutomationBridge.queue.asUnownedSerialExecutor() }
  private var connections: [UUID: ChromiumAutomationConnection] = [:]

  func add(_ connection: ChromiumAutomationConnection) { connections[connection.id] = connection }
  func remove(_ id: UUID) { connections[id] = nil }

  func event(_ data: Data, model: ChromiumBrowserModel) {
    guard !connections.isEmpty, let message = BrowserProtocolMessage(data), let method = message.string("method")
    else { return }
    let machineId = model.machineId
    for connection in connections.values where connection.machineId == machineId {
      connection.assumeIsolated { $0.event(message, method: method, model: model) }
    }
  }

  func download(_ download: ChromiumAutomationDownload, model: ChromiumBrowserModel) {
    let machineId = model.machineId
    for connection in connections.values where connection.machineId == machineId {
      connection.assumeIsolated { $0.download(download, model: model) }
    }
  }

  func permissionRefused(_ permissions: [String], origin: String, model: ChromiumBrowserModel) {
    let machineId = model.machineId
    for connection in connections.values where connection.machineId == machineId {
      connection.assumeIsolated { $0.permissionRefused(permissions, origin: origin, model: model) }
    }
  }

  func broadcast(_ event: TargetEvent) {
    let (message, machineId): ([String: Any], String) =
      switch event {
      case .targetCreated(let info, let machineId):
        (["method": "Target.targetCreated", "params": ["targetInfo": info.json]], machineId)
      case .targetDestroyed(let id, let machineId):
        (["method": "Target.targetDestroyed", "params": ["targetId": id]], machineId)
      }
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    for connection in connections.values where connection.machineId == machineId {
      connection.assumeIsolated { if $0.authenticated { $0.send(data) } }
    }
  }
}
