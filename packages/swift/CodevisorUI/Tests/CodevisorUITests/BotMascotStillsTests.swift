import CodevisorCore
import CoreGraphics
import Foundation
import Metal
import Testing

@testable import CodevisorUI

@Suite("Bot mascot stills")
@MainActor
struct BotMascotStillsTests {
  private static let mascot = ServerBotMascot(color: "mint", hat: "beanie", eyewear: "specs")
  private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("BotMascotStillsTests-\(UUID().uuidString)", isDirectory: true)

  @Test("A still drawn on an earlier launch shows on the first lookup, before anything draws")
  func earlierLaunchShowsAtOnce() throws {
    let still = BotMascotStill(Self.mascot, framing: .portrait)
    BotMascotStillDisk(root: root, version: "a").store(try Self.image(), as: still)

    let relaunched = BotMascotStills(disk: BotMascotStillDisk(root: root, version: "a"))

    #expect(relaunched.image(for: still)?.width == 8)
  }

  @Test("A still drawn from older art isn't shown once the app's art changes")
  func olderArtIsRedrawn() throws {
    let still = BotMascotStill(Self.mascot, framing: .portrait)
    BotMascotStillDisk(root: root, version: "a").store(try Self.image(), as: still)

    let updated = BotMascotStills(disk: BotMascotStillDisk(root: root, version: "b"))

    #expect(updated.image(for: still) == nil)
  }

  @Test(
    "A mascot is drawn from the art the app ships with, with no machine",
    .enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func drawsFromBundledArt() async throws {
    let still = BotMascotStill(Self.mascot, framing: .figure)
    let stills = BotMascotStills(disk: BotMascotStillDisk(root: root, version: "a"))

    await stills.load(still)

    let image = try #require(stills.image(for: still))
    #expect(abs(image.width - BotMascotStill.pixels) <= 1)
    #expect(Self.paintedFraction(of: image) > 0.2)
    #expect(BotMascotStills(disk: BotMascotStillDisk(root: root, version: "a")).image(for: still) != nil)
  }

  private static func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return try #require(context.makeImage())
  }

  private static func paintedFraction(of image: CGImage) -> Double {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let painted = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
    return Double(painted) / Double(width * height)
  }
}
