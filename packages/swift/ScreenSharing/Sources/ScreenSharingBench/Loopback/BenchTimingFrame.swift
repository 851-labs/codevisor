import Foundation

public struct BenchTimingFrame: Sendable, Equatable, Hashable {
  private static let fieldCount = 15
  private enum Field: Int {
    case rtpTimestamp = 0
    case captureTime = 1
    case encodeStart = 2
    case encodeFinish = 3
    case decodeStart = 10
    case decodeFinish = 11
  }

  public let rtpTimestamp: UInt32
  public let captureMs: Double
  public let encodeMs: Double
  public let decodeMs: Double
  public let captureToDecodedMs: Double

  public init?(statisticsValue text: String) {
    let fields = text.split(separator: ",", omittingEmptySubsequences: false).map {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard fields.count == Self.fieldCount, let rtp = fields[Field.rtpTimestamp.rawValue].flatMap(UInt32.init(exactly:))
    else { return nil }

    guard let capture = fields[Field.captureTime.rawValue], let encodeStart = fields[Field.encodeStart.rawValue],
      let encodeFinish = fields[Field.encodeFinish.rawValue], let decodeStart = fields[Field.decodeStart.rawValue],
      let decodeFinish = fields[Field.decodeFinish.rawValue],
      [capture, encodeStart, encodeFinish, decodeStart, decodeFinish].allSatisfy({ $0 >= 0 })
    else { return nil }

    rtpTimestamp = rtp
    captureMs = capture
    encodeMs = encodeFinish - encodeStart
    decodeMs = decodeFinish - decodeStart
    captureToDecodedMs = decodeFinish - capture
  }
}
