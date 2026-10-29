import Darwin

enum BenchHostName {
  static var current: String {
    var name = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
    guard gethostname(&name, name.count) == 0 else { return "unknown" }

    return String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }
}
