import Foundation

enum ScreenSharingHostTimingMarker {
  private static let userDataUnregistered: UInt8 = 5
  private static let kind: UInt8 = 0x81
  private static let clockGroups = 10
  private static let durationGroups = 5
  private static let payloadSize = ScreenSharingSourceMarker.identifier.count + 1 + clockGroups + 3 * durationGroups
  private static let trailingBits: UInt8 = 0x80
  private static let groupBit: UInt8 = 0x80

  static func append(_ timing: ScreenSharingHostFrameTiming, codec: ScreenSharingVideoCodec, to data: inout Data) {
    appendHeader(codec, to: &data)
    data.append(userDataUnregistered)
    data.append(UInt8(payloadSize))
    data.append(contentsOf: ScreenSharingSourceMarker.identifier)
    data.append(kind)
    appendGroups(timing.clock, count: clockGroups, to: &data)
    appendGroups(UInt64(timing.captureUs), count: durationGroups, to: &data)
    appendGroups(UInt64(timing.hostQueueUs), count: durationGroups, to: &data)
    appendGroups(UInt64(timing.encodeUs), count: durationGroups, to: &data)
    data.append(trailingBits)
  }

  static func timing(in units: [Data], codec: ScreenSharingVideoCodec) -> ScreenSharingHostFrameTiming? {
    for unit in units {
      if let timing = timing(in: unit, codec: codec) { return timing }
    }
    return nil
  }

  static func timing(in unit: Data, codec: ScreenSharingVideoCodec) -> ScreenSharingHostFrameTiming? {
    let start = headerCount(codec) + 2
    guard isTimingUnit(unit, codec: codec, payloadStart: start) else { return nil }

    let fields = start + ScreenSharingSourceMarker.identifier.count + 1
    let captureStart = fields + clockGroups
    guard let clock = groups(unit, from: fields, count: clockGroups),
      let capture = groups(unit, from: captureStart, count: durationGroups),
      let queue = groups(unit, from: captureStart + durationGroups, count: durationGroups),
      let encode = groups(unit, from: captureStart + 2 * durationGroups, count: durationGroups)
    else { return nil }

    return ScreenSharingHostFrameTiming(
      clock: clock, captureUs: Int64(capture), hostQueueUs: Int64(queue), encodeUs: Int64(encode))
  }

  private static func isTimingUnit(_ unit: Data, codec: ScreenSharingVideoCodec, payloadStart: Int) -> Bool {
    guard unit.count == payloadStart + payloadSize + 1 else { return false }
    guard hasHeader(unit, codec: codec), byte(unit, payloadStart - 2) == userDataUnregistered else { return false }
    guard byte(unit, payloadStart - 1) == UInt8(payloadSize), byte(unit, unit.count - 1) == trailingBits else {
      return false
    }
    return hasIdentifier(unit, from: payloadStart)
      && byte(unit, payloadStart + ScreenSharingSourceMarker.identifier.count) == kind
  }

  private static func hasHeader(_ unit: Data, codec: ScreenSharingVideoCodec) -> Bool {
    if codec == .h264 { return byte(unit, 0) == 0x06 }
    return byte(unit, 0) == 0x4e && byte(unit, 1) == 0x01
  }

  private static func hasIdentifier(_ unit: Data, from start: Int) -> Bool {
    for (offset, expected) in ScreenSharingSourceMarker.identifier.enumerated()
    where byte(unit, start + offset) != expected {
      return false
    }
    return true
  }

  private static func groups(_ unit: Data, from start: Int, count: Int) -> UInt64? {
    var value: UInt64 = 0
    for offset in 0..<count {
      let group = byte(unit, start + offset)
      guard group & groupBit != 0, value >> 57 == 0 else { return nil }
      value = (value << 7) | UInt64(group & ~groupBit)
    }
    return value
  }

  private static func appendGroups(_ value: UInt64, count: Int, to data: inout Data) {
    for index in (0..<count).reversed() {
      data.append(groupBit | UInt8((value >> (7 * index)) & 0x7f))
    }
  }

  private static func appendHeader(_ codec: ScreenSharingVideoCodec, to data: inout Data) {
    if codec == .h264 {
      data.append(0x06)
      return
    }
    data.append(0x4e)
    data.append(0x01)
  }

  private static func headerCount(_ codec: ScreenSharingVideoCodec) -> Int { codec == .h264 ? 1 : 2 }

  private static func byte(_ unit: Data, _ offset: Int) -> UInt8 { unit[unit.startIndex + offset] }
}
