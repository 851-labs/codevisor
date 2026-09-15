import Foundation
import QuartzCore

/// A parsed HTTP/1.1 request. Header names are lowercased.
public struct RigHTTPRequest: Equatable, Sendable {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data
  /// `CACurrentMediaTime` when the request was fully received; 0 when constructed by hand.
  public let receivedAtSeconds: Double

  public init(method: String, path: String, headers: [String: String], body: Data, receivedAtSeconds: Double = 0) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
    self.receivedAtSeconds = receivedAtSeconds
  }
}

public enum RigHTTPParseResult: Equatable, Sendable {
  case incomplete
  case invalid(String)
  case complete(RigHTTPRequest, consumed: Int)
}

/// Just enough HTTP/1.1 for one request per connection on a trusted LAN: no
/// chunked encoding, no keep-alive, bounded sizes.
public enum RigHTTPCodec {
  public static let maximumHeaderBytes = 16_384
  public static let maximumBodyBytes = 524_288

  public static func parse(_ data: Data) -> RigHTTPParseResult {
    let bytes = [UInt8](data)
    guard let headerEnd = indexOfCRLFCRLF(bytes) else {
      return bytes.count > maximumHeaderBytes ? .invalid("headers exceed \(maximumHeaderBytes) bytes") : .incomplete
    }
    guard headerEnd <= maximumHeaderBytes else { return .invalid("headers exceed \(maximumHeaderBytes) bytes") }
    let headerText = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
    var lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .invalid("missing request line") }
    lines.removeFirst()
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isUppercase && $0.isLetter }),
      parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
    else { return .invalid("malformed request line") }
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return .invalid("malformed header") }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return .invalid("malformed header") }
      headers[name] = value
    }
    var length = 0
    if let raw = headers["content-length"] {
      guard let parsed = Int(raw), parsed >= 0 else { return .invalid("malformed content-length") }
      guard parsed <= maximumBodyBytes else { return .invalid("body exceeds \(maximumBodyBytes) bytes") }
      length = parsed
    }
    if headers["transfer-encoding"] != nil { return .invalid("transfer-encoding is not supported") }
    let bodyStart = headerEnd + 4
    guard bytes.count - bodyStart >= length else { return .incomplete }
    let body = Data(bytes[bodyStart..<(bodyStart + length)])
    return .complete(
      RigHTTPRequest(
        method: String(parts[0]), path: String(parts[1]), headers: headers, body: body,
        receivedAtSeconds: CACurrentMediaTime()),
      consumed: bodyStart + length)
  }

  public static func response(status: Int, body: Data, contentType: String = "application/json") -> Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 404: reason = "Not Found"
    case 405: reason = "Method Not Allowed"
    case 409: reason = "Conflict"
    case 413: reason = "Payload Too Large"
    case 500: reason = "Internal Server Error"
    case 503: reason = "Service Unavailable"
    default: reason = "Status"
    }
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Cache-Control: no-store\r\n"
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8) + body
  }

  /// `Authorization: Bearer <token>`, compared in constant time.
  public static func isAuthorized(_ request: RigHTTPRequest, token: String) -> Bool {
    guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
    let presented = Array(header.dropFirst("Bearer ".count).utf8)
    let expected = Array(token.utf8)
    guard presented.count == expected.count, !expected.isEmpty else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(presented, expected) { difference |= left ^ right }
    return difference == 0
  }

  private static func indexOfCRLFCRLF(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    var index = 0
    while index + 3 < bytes.count {
      if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 { return index }
      index += 1
    }
    return nil
  }
}
