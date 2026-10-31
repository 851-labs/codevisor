import Foundation
import ScreenSharing

struct ScreenSharingV2AccessUnitLayout: Equatable {
  private static let lengthSize = 4
  private static let parameterSetTypes: ClosedRange<UInt8> = 32...34

  let parameterSets: [Data]
  let sliceOffset: Int

  init(_ bytes: UnsafeRawBufferPointer) throws {
    var parameterSets: [Data] = []
    var offset = 0
    while let unit = try Self.unit(in: bytes, at: offset), Self.parameterSetTypes.contains(Self.type(of: unit)) {
      parameterSets.append(Data(unit))
      offset = unit.endIndex
    }
    guard offset < bytes.count else { throw ScreenSharingError.invalid("The access unit has no slices.") }

    self.parameterSets = parameterSets
    self.sliceOffset = offset
  }

  private static func unit(in bytes: UnsafeRawBufferPointer, at offset: Int) throws -> Slice<UnsafeRawBufferPointer>? {
    guard offset + lengthSize <= bytes.count else { return nil }

    let length = bytes[offset..<(offset + lengthSize)].reduce(0) { ($0 << 8) | Int($1) }
    let start = offset + lengthSize
    guard length >= 2, start + length <= bytes.count else { throw ScreenSharingError.invalid("Malformed NAL unit.") }

    return bytes[start..<(start + length)]
  }

  private static func type(of unit: Slice<UnsafeRawBufferPointer>) -> UInt8 {
    (unit[unit.startIndex] >> 1) & 0x3f
  }
}
