import Foundation
import Testing

@testable import CodevisorBench

struct ReopenRecordTests {
  private static let codevisor = "/Applications/Codevisor.app"

  @Test func keepsAnAppAnEarlierJobQuitWhenNothingIsOpenNow() throws {
    let record = try Self.record(holding: "\(Self.codevisor)\n")

    try record.add([])

    #expect(try Self.contents(of: record) == "\(Self.codevisor)\n")
  }

  @Test func listsAnAppOnceHoweverOftenItIsQuit() throws {
    let record = try Self.record(holding: nil)

    try record.add([Self.codevisor])
    try record.add([Self.codevisor, "/Applications/Other.app"])

    #expect(try Self.contents(of: record) == "\(Self.codevisor)\n/Applications/Other.app\n")
  }

  @Test func writesNothingWhenNoAppWasOpen() throws {
    let record = try Self.record(holding: nil)

    try record.add([])

    #expect(!FileManager.default.fileExists(atPath: record.path))
  }

  private static func record(holding contents: String?) throws -> ReopenRecord {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = ReopenRecord(path: directory.appendingPathComponent("reopen-apps.txt").path)
    try contents?.write(toFile: record.path, atomically: true, encoding: .utf8)
    return record
  }

  private static func contents(of record: ReopenRecord) throws -> String {
    try String(contentsOfFile: record.path, encoding: .utf8)
  }
}
