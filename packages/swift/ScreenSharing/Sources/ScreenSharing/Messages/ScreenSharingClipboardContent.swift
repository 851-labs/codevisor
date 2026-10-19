import Foundation

public struct ScreenSharingClipboardContent: Sendable, Equatable {
  public struct Representation: Sendable, Equatable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
  }

  public static let textType = "public.utf8-plain-text"
  public static let maximumTypeBytes = 256
  public var items: [[Representation]]

  public init(items: [[Representation]]) { self.items = items }
  public init(text: String) { items = [[Representation(type: Self.textType, data: Data(text.utf8))]] }

  public var text: String? {
    items.lazy.flatMap { $0 }.first { $0.type == Self.textType }.flatMap { String(data: $0.data, encoding: .utf8) }
  }
  public var byteCount: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } } }

  public func archived() throws -> Data {
    var archive = Data()
    func append(_ value: Int) { archive.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian, Array.init)) }
    append(items.count)
    for item in items {
      append(item.count)
      for representation in item {
        let type = Data(representation.type.utf8)
        guard (1...Self.maximumTypeBytes).contains(type.count), representation.data.count <= UInt32.max else {
          throw ScreenSharingError.invalid("Clipboard type is invalid.")
        }
        append(type.count); archive.append(type)
        append(representation.data.count); archive.append(representation.data)
      }
    }
    return archive
  }

  public static func unarchived(_ archive: Data) throws -> Self {
    let bytes = [UInt8](archive)
    var offset = 0
    func take(_ count: Int) throws -> ArraySlice<UInt8> {
      guard count >= 0, count <= bytes.count - offset else {
        throw ScreenSharingError.invalid("Clipboard data was truncated.")
      }
      defer { offset += count }
      return bytes[offset..<offset + count]
    }
    func number() throws -> Int { try take(4).reduce(0) { $0 << 8 | Int($1) } }
    let itemCount = try number()
    guard itemCount > 0, itemCount <= bytes.count else { throw ScreenSharingError.invalid("Clipboard data was empty.") }
    var items: [[Representation]] = []
    for _ in 0..<itemCount {
      let count = try number()
      guard count > 0, count <= bytes.count else { throw ScreenSharingError.invalid("Clipboard data was empty.") }
      var item: [Representation] = []
      for _ in 0..<count {
        let typeBytes = try number()
        guard (1...maximumTypeBytes).contains(typeBytes), let type = String(bytes: try take(typeBytes), encoding: .utf8)
        else { throw ScreenSharingError.invalid("Clipboard type is invalid.") }
        item.append(Representation(type: type, data: Data(try take(try number()))))
      }
      items.append(item)
    }
    guard offset == bytes.count else { throw ScreenSharingError.invalid("Clipboard data had trailing bytes.") }
    return Self(items: items)
  }
}
