import Foundation

public struct BenchLab: Sendable, Equatable {
  private static let whiteX = 0.95047
  private static let whiteZ = 1.08883
  private static let epsilon = 216.0 / 24389
  private static let kappa = 24389.0 / 27

  public var lightness: Double
  public var a: Double
  public var b: Double

  public init(lightness: Double, a: Double, b: Double) {
    self.lightness = lightness
    self.a = a
    self.b = b
  }

  public init(_ color: BenchRGB) {
    let red = Self.linear(color.red)
    let green = Self.linear(color.green)
    let blue = Self.linear(color.blue)
    let x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / Self.whiteX
    let y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
    let z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / Self.whiteZ
    let (fx, fy, fz) = (Self.f(x), Self.f(y), Self.f(z))
    self.init(lightness: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
  }

  private static func linear(_ channel: UInt8) -> Double {
    let value = Double(channel) / 255
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  private static func f(_ t: Double) -> Double {
    t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
  }
}
