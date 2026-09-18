import ScreenSharing
import CoreImage
import CoreText
import Foundation

/// Immutable drawing resources shared by the visible desktop target and the
/// synthetic source. Each owner draws on its own serial queue.
package final class ProbeDesktopPainter: @unchecked Sendable {
  package let pattern: CGImage
  package let fps: Int
  // Use a concrete, retained CTFont like the source pattern. Repeated AppKit
  // system-font resolution in NSString.draw raised a CoreText exception on
  // the macOS 26 host during an extended workload run.
  private let textAttributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 20, nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
  ]

  package init(pattern: CGImage, fps: Int) { self.pattern = pattern; self.fps = fps }

  package static func make(width: Int, height: Int, fps: Int) throws -> ProbeDesktopPainter {
    let pixel = try ProbeCodecPattern.make(width: width, height: height, sequence: 0)
    let source = CIImage(cvPixelBuffer: pixel)
    guard let pattern = CIContext().createCGImage(source, from: source.extent) else {
      throw ScreenSharingError.unavailable("Cannot prepare desktop pattern.")
    }
    return ProbeDesktopPainter(pattern: pattern, fps: fps)
  }

  package func draw(in context: CGContext, bounds: CGRect, sequence: Int, responses: Int) {
    let width = CGFloat(pattern.width)
    let height = CGFloat(pattern.height)
    context.saveGState()
    defer { context.restoreGState() }
    context.scaleBy(x: bounds.width / width, y: bounds.height / height)
    context.interpolationQuality = .none
    let offset = CGFloat(sequence % 22)
    context.setFillColor(CGColor(gray: 0.06, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(pattern, in: CGRect(x: 0, y: offset, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.06, alpha: 1))
    context.fill(CGRect(x: 0, y: height - 140, width: width, height: 140))
    drawText("Codevisor benchmark · frame \(sequence) · responses \(responses)", x: 24, y: height - 40, in: context)
    drawText(
      "Click or press Space · time-driven frame code below · \(fps) fps requested", x: 24, y: height - 70, in: context)
    // 18 bits, MSB first, fit the full one-hour / 60 fps CLI range. A white
    // reference cell precedes the data; a black cell follows it.
    for bit in 0..<20 {
      let on = bit == 0 || (bit < 19 && (sequence & (1 << (18 - bit))) != 0)
      context.setFillColor(CGColor(gray: on ? 1 : 0, alpha: 1))
      context.fill(CGRect(x: 24 + bit * 28, y: Int(height) - 120, width: 24, height: 30))
    }
    context.setFillColor(
      responses.isMultiple(of: 2)
        ? CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1)
        : CGColor(red: 1, green: 0.3, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: width - 300, y: height - 125, width: 276, height: 105))
    drawText("Response \(responses)", x: width - 280, y: height - 75, in: context)
    context.setFillColor(CGColor(red: 0.2, green: 1, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: CGFloat((sequence * 7) % pattern.width), y: 70, width: 80, height: 20))
  }

  private func drawText(_ text: String, x: CGFloat, y: CGFloat, in context: CGContext) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: textAttributes))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
  }
}
