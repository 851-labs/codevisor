import Darwin

enum PeerAddress {
  private static let linkLocalScopeBytes = 2...3

  static func resolve(_ entries: [String]) -> Set<String> {
    Set(entries.flatMap(addresses))
  }

  static func normalized(_ text: String) -> String {
    let address = text.split(separator: "%").first.map(String.init) ?? text
    var bytes = in6_addr()
    guard inet_pton(AF_INET6, address, &bytes) == 1 else { return address }

    withUnsafeMutableBytes(of: &bytes) { raw in
      guard raw[0] == 0xfe, raw[1] & 0xc0 == 0x80 else { return }

      for index in linkLocalScopeBytes { raw[index] = 0 }
    }
    return text6(bytes)
  }

  private static func addresses(_ entry: String) -> [String] {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(entry, nil, &hints, &list) == 0, let first = list else { return [normalized(entry)] }
    defer { freeaddrinfo(list) }

    return Array(sequence(first: first) { $0.pointee.ai_next }.compactMap(text))
  }

  private static func text(_ info: UnsafeMutablePointer<addrinfo>) -> String? {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = getnameinfo(
      info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    guard status == 0 else { return nil }

    return normalized(String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self))
  }

  private static func text6(_ address: in6_addr) -> String {
    var address = address
    var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
    return String(decoding: text.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }
}
