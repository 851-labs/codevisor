public struct BenchRGB: Sendable, Equatable, Hashable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  func largestChannelDifference(from other: BenchRGB) -> Int {
    max(
      abs(Int(red) - Int(other.red)), abs(Int(green) - Int(other.green)), abs(Int(blue) - Int(other.blue)))
  }
}
