import Foundation

enum BenchConsole {
  static func error(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
  }
}
