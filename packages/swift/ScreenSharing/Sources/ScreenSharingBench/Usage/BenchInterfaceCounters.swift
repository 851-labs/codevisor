import Darwin

public struct BenchInterfaceCounters: Sendable, Equatable {
  public let sampledNs: Int64
  public let receivedBytes: UInt64
  public let sentBytes: UInt64

  public init(sampledNs: Int64, receivedBytes: UInt64, sentBytes: UInt64) {
    self.sampledNs = sampledNs
    self.receivedBytes = receivedBytes
    self.sentBytes = sentBytes
  }

  public static func sample(interface name: String) throws -> BenchInterfaceCounters {
    guard let index = UInt16(exactly: if_nametoindex(name)), index != 0 else {
      throw BenchInterfaceCountersError.unknownInterface(name)
    }
    guard let data = try statistics(forIndex: index, in: interfaceTable()) else {
      throw BenchInterfaceCountersError.unknownInterface(name)
    }

    return BenchInterfaceCounters(
      sampledNs: BenchMachClock.nowNs(), receivedBytes: data.ifi_ibytes, sentBytes: data.ifi_obytes)
  }

  private static let messageTypeOffset = MemoryLayout<if_msghdr2>.offset(of: \.ifm_type)!

  private static func interfaceTable() throws -> [UInt8] {
    var request: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length = 0
    guard sysctl(&request, UInt32(request.count), nil, &length, nil, 0) == 0 else { throw tableError() }

    var table = [UInt8](repeating: 0, count: length)
    guard sysctl(&request, UInt32(request.count), &table, &length, nil, 0) == 0 else { throw tableError() }

    return Array(table.prefix(length))
  }

  private static func statistics(forIndex index: UInt16, in table: [UInt8]) -> if_data64? {
    var offset = 0
    while offset + messageTypeOffset < table.count {
      let length = Int(table.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) })
      guard length > 0 else { return nil }

      if let message = interfaceInfo(at: offset, in: table), message.ifm_index == index { return message.ifm_data }
      offset += length
    }
    return nil
  }

  private static func interfaceInfo(at offset: Int, in table: [UInt8]) -> if_msghdr2? {
    guard Int32(table[offset + messageTypeOffset]) == RTM_IFINFO2 else { return nil }
    guard offset + MemoryLayout<if_msghdr2>.size <= table.count else { return nil }

    return table.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
  }

  private static func tableError() -> BenchInterfaceCountersError {
    .unavailable(errno: errno)
  }
}

public enum BenchInterfaceCountersError: Error, Equatable {
  case unknownInterface(String)
  case unavailable(errno: Int32)
}
