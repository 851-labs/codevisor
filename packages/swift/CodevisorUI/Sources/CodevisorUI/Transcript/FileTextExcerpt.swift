import Foundation

public struct FileTextExcerpt: Equatable, Sendable {
  public static let byteLimit = 64 * 1_024
  public static let lineLimit = 400

  public let content: String
  public let lineCount: Int?

  public var isTruncated: Bool { lineCount == nil }

  public init?(data: Data) {
    let isCut = data.count > Self.byteLimit
    let bytes = Self.wholeLines(of: data.prefix(Self.byteLimit), isCut: isCut)
    guard !bytes.contains(0), let text = Self.decoded(bytes, isCut: isCut) else { return nil }

    let lines = Self.lines(of: text)
    let isTruncated = isCut || lines.count > Self.lineLimit
    content = lines.prefix(Self.lineLimit).joined(separator: "\n")
    lineCount = isTruncated ? nil : lines.count
  }

  private static func wholeLines(of bytes: Data, isCut: Bool) -> Data {
    guard isCut, let newline = bytes.lastIndex(of: newlineByte) else { return bytes }
    return bytes[..<newline]
  }

  private static func decoded(_ bytes: Data, isCut: Bool) -> String? {
    let trims = isCut ? 0...maximumScalarTail : 0...0
    return trims.lazy.compactMap { String(data: bytes.dropLast($0), encoding: .utf8) }.first
  }

  private static func lines(of text: String) -> [Substring] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard !normalized.isEmpty else { return [] }
    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
    return lines
  }

  private static let newlineByte: UInt8 = 0x0A
  private static let maximumScalarTail = 3
}
