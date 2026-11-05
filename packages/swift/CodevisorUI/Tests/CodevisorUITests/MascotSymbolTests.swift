#if os(macOS)
  import AppKit
  import Testing
  @testable import CodevisorUI

  @Suite("Mascot symbols")
  struct MascotSymbolTests {
    @Test(
      "Each mascot symbol draws heavier at each heavier weight",
      arguments: [CodevisorSymbol.mascot, .mascotFill, .mascotBadgePlus, .mascotFillBadgePlus])
    func weightsInterpolate(symbol: CodevisorSymbol) throws {
      let ink = try [NSFont.Weight.ultraLight, .regular, .black].map { try inkCoverage(symbol, weight: $0) }
      #expect(ink[0] < ink[1])
      #expect(ink[1] < ink[2])
    }

    private func inkCoverage(_ symbol: CodevisorSymbol, weight: NSFont.Weight) throws -> Int {
      let image = try #require(
        NSImage(symbolName: symbol.rawValue, bundle: .module, variableValue: 0)?
          .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: weight))?
          .cgImage(forProposedRect: nil, context: nil, hints: nil))
      let context = try #require(
        CGContext(
          data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      return (0..<image.width * image.height).reduce(0) { $0 + Int(pixels[$1 * 4 + 3]) }
    }
  }
#endif
