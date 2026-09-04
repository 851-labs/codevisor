import Darwin
import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use socket discovery")
struct ComputerUseBridgeSocketTests {
  @Test("Shares the server socket address across users and Unicode data paths")
  func serverSocketContract() {
    // The server test uses this same fixture to check the wire contract.
    let path = "/Users/test/Codevisor café/data"
    let socketPath = ComputerUseBridge.socketPath(supportDirectoryPath: path, userID: 501)
    #expect(socketPath == "/tmp/codevisor-cu-501-26606633.sock")
    #expect(ComputerUseBridge.socketPath(supportDirectoryPath: path, userID: 502) != socketPath)
    #expect(
      ComputerUseBridge.socketPath(supportDirectoryPath: path + "/other", userID: 501) != socketPath)
  }

  @Test("Starts a discoverable socket for deeply nested development data")
  func deepDevelopmentDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-bridge-test-\(UUID().uuidString)", isDirectory: true)
    let dataDirectory = root.appendingPathComponent(String(repeating: "worktree-", count: 20))
    let bridge = ComputerUseBridge(supportDirectory: dataDirectory)
    defer {
      bridge.stop()
      try? FileManager.default.removeItem(at: root)
    }

    let configuration = try bridge.start()
    #expect(configuration.socketPath.hasPrefix("/tmp/codevisor-cu-"))
    #expect(configuration.socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))
    #expect(FileManager.default.fileExists(atPath: configuration.socketPath))
    let attributes = try FileManager.default.attributesOfItem(atPath: configuration.socketPath)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(
      try String(contentsOf: dataDirectory.appendingPathComponent("computer-use-token"), encoding: .utf8)
        == configuration.token)

    bridge.stop()
    #expect(!FileManager.default.fileExists(atPath: configuration.socketPath))
  }
}
