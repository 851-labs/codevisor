import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Server process ownership")
struct ServerProcessOwnershipTests {
  @Test("A live owner blocks replacement and an unrelated executable is never signalled")
  func liveOwner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["600"]
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let path = directory.appendingPathComponent("db.sqlite").path
    let data = try JSONSerialization.data(withJSONObject: [
      "pid": process.processIdentifier, "bootId": "boot", "databasePath": path,
    ])
    try data.write(to: URL(fileURLWithPath: path + ".server-owner.json"))
    let owner = try #require(ServerProcessOwnership.owner(databasePath: path))
    #expect(await !ServerProcessOwnership.hasStopped(port: 1, databasePath: path, previousOwner: owner))
    await ServerProcessOwnership.terminate(owner, databasePath: path)
    #expect(process.isRunning)
    // A changed identity is also insufficient authority to signal the PID.
    var stale = owner
    stale.bootId = "previous"
    await ServerProcessOwnership.terminate(stale, databasePath: path)
    #expect(process.isRunning)
  }

  @Test("A fresh database heartbeat blocks replacement without an owner record")
  func databaseHeartbeat() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let path = directory.appendingPathComponent("db.sqlite").path
    try FileManager.default.createDirectory(atPath: path + ".lock", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(ServerProcessOwnership.owner(databasePath: path) == nil)
    #expect(await !ServerProcessOwnership.hasStopped(port: 1, databasePath: path, previousOwner: nil))
  }

  @Test("A listener blocks replacement even after the database lease is gone")
  func portOwnership() async throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    #expect(bound == 0)
    #expect(listen(descriptor, 1) == 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
    }
    #expect(named == 0)
    let port = Int(UInt16(bigEndian: address.sin_port))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    #expect(await !ServerProcessOwnership.hasStopped(port: port, databasePath: path, previousOwner: nil))
  }
}
