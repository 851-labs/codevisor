import Foundation
import ScreenSharingBench

enum ResultsFiles {
  static func report(at path: String) throws -> BenchReport {
    try BenchReportCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
  }

  static func index(at path: String?) throws -> [BenchIndexEntry] {
    guard let path, FileManager.default.fileExists(atPath: path) else { return [] }

    return try BenchIndex.entries(Data(contentsOf: URL(fileURLWithPath: path)))
  }
}
