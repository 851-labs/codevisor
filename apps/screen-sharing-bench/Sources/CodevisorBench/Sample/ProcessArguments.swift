import Darwin

enum ProcessArguments {
  static func of(_ pid: pid_t) -> [String] {
    guard let bytes = rawArguments(pid), bytes.count > MemoryLayout<Int32>.size else { return [] }

    let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    let strings = bytes.dropFirst(MemoryLayout<Int32>.size).split(separator: 0, omittingEmptySubsequences: true)
    return strings.dropFirst().prefix(count).map { String(decoding: $0, as: UTF8.self) }
  }

  private static func rawArguments(_ pid: pid_t) -> [UInt8]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }

    return Array(bytes.prefix(size))
  }
}
