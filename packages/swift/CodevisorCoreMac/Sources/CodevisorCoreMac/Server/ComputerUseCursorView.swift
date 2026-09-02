import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

final class ComputerUseCursorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// The transparent glow may extend beyond a screen edge. Returning the
  /// requested frame prevents AppKit from moving the cursor hotspot away
  /// from the event coordinate when the panel is ordered onscreen.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

struct ComputerUsePointerArtwork {
  let cgPath: CGPath
  let tip: CGPoint

  var path: NSBezierPath {
    NSBezierPath(cgPath: cgPath)
  }
}

/// The supplied 24×24 SVG path, converted from SVG's top-left coordinate
/// system to AppKit and rotated left around its real tip. Keeping the tip as a
/// first-class point lets the overlay place it exactly on the click target.
func computerUsePointerArtwork(
  size: CGSize,
  rotation: CGFloat = ComputerUseCursorMetrics.artworkRotation
) -> ComputerUsePointerArtwork {
  let svgPath = CGMutablePath()
  svgPath.move(to: CGPoint(x: 19.8683, y: 18.4886))
  svgPath.addLine(to: CGPoint(x: 13.8696, y: 4.16156))
  svgPath.addCurve(
    to: CGPoint(x: 13.1358, y: 3.31858),
    control1: CGPoint(x: 13.7257, y: 3.82006),
    control2: CGPoint(x: 13.4698, y: 3.52606)
  )
  svgPath.addCurve(
    to: CGPoint(x: 12, y: 3),
    control1: CGPoint(x: 12.8019, y: 3.11111),
    control2: CGPoint(x: 12.4058, y: 3)
  )
  svgPath.addCurve(
    to: CGPoint(x: 10.8642, y: 3.31858),
    control1: CGPoint(x: 11.5942, y: 3),
    control2: CGPoint(x: 11.1981, y: 3.11111)
  )
  svgPath.addCurve(
    to: CGPoint(x: 10.1304, y: 4.16156),
    control1: CGPoint(x: 10.5302, y: 3.52606),
    control2: CGPoint(x: 10.2743, y: 3.82006)
  )
  svgPath.addLine(to: CGPoint(x: 4.13171, y: 18.4886))
  svgPath.addCurve(
    to: CGPoint(x: 4.07537, y: 19.6206),
    control1: CGPoint(x: 3.97804, y: 18.8506),
    control2: CGPoint(x: 3.95828, y: 19.2476)
  )
  svgPath.addCurve(
    to: CGPoint(x: 4.78157, y: 20.5585),
    control1: CGPoint(x: 4.19245, y: 19.9935),
    control2: CGPoint(x: 4.44013, y: 20.3224)
  )
  svgPath.addCurve(
    to: CGPoint(x: 6.17127, y: 20.9995),
    control1: CGPoint(x: 5.1751, y: 20.8443),
    control2: CGPoint(x: 5.66562, y: 20.9999)
  )
  svgPath.addCurve(
    to: CGPoint(x: 7.401, y: 20.6665),
    control1: CGPoint(x: 6.6085, y: 20.9989),
    control2: CGPoint(x: 7.03599, y: 20.8832)
  )
  svgPath.addLine(to: CGPoint(x: 12, y: 17.9127))
  svgPath.addLine(to: CGPoint(x: 16.599, y: 20.6665))
  svgPath.addCurve(
    to: CGPoint(x: 17.9283, y: 20.9979),
    control1: CGPoint(x: 16.9918, y: 20.9012),
    control2: CGPoint(x: 17.4574, y: 21.0173)
  )
  svgPath.addCurve(
    to: CGPoint(x: 19.2184, y: 20.5585),
    control1: CGPoint(x: 18.3993, y: 20.9785),
    control2: CGPoint(x: 18.8512, y: 20.8246)
  )
  svgPath.addCurve(
    to: CGPoint(x: 19.9246, y: 19.6206),
    control1: CGPoint(x: 19.5599, y: 20.3224),
    control2: CGPoint(x: 19.8075, y: 19.9935)
  )
  svgPath.addCurve(
    to: CGPoint(x: 19.8683, y: 18.4886),
    control1: CGPoint(x: 20.0417, y: 19.2476),
    control2: CGPoint(x: 20.022, y: 18.8506)
  )
  svgPath.closeSubpath()

  var svgToAppKit = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 24)
  let appKitPath = svgPath.copy(using: &svgToAppKit) ?? svgPath
  let appKitTip = CGPoint(x: 12, y: 21)

  var artworkRotation = CGAffineTransform.identity
  artworkRotation = artworkRotation.translatedBy(x: appKitTip.x, y: appKitTip.y)
  artworkRotation = artworkRotation.rotated(by: rotation)
  artworkRotation = artworkRotation.translatedBy(x: -appKitTip.x, y: -appKitTip.y)
  let rotatedPath = appKitPath.copy(using: &artworkRotation) ?? appKitPath
  let rotatedTip = appKitTip.applying(artworkRotation)
  let sourceBounds = rotatedPath.boundingBoxOfPath
  let scale = min(
    size.width / max(0.001, sourceBounds.width),
    size.height / max(0.001, sourceBounds.height)
  )
  let xInset = (size.width - sourceBounds.width * scale) / 2
  let yInset = (size.height - sourceBounds.height * scale) / 2
  var normalize = CGAffineTransform(
    a: scale,
    b: 0,
    c: 0,
    d: scale,
    tx: -sourceBounds.minX * scale + xInset,
    ty: -sourceBounds.minY * scale + yInset
  )
  let normalizedPath = rotatedPath.copy(using: &normalize) ?? rotatedPath
  return ComputerUsePointerArtwork(
    cgPath: normalizedPath,
    tip: rotatedTip.applying(normalize)
  )
}

func computerUsePointerPath(tip: CGPoint, size: CGSize) -> NSBezierPath {
  let artwork = computerUsePointerArtwork(size: size)
  var placement = CGAffineTransform(
    translationX: tip.x - artwork.tip.x,
    y: tip.y - artwork.tip.y
  )
  return NSBezierPath(cgPath: artwork.cgPath.copy(using: &placement) ?? artwork.cgPath)
}

func computerUsePointerPath(
  in rect: CGRect,
  rotation: CGFloat = ComputerUseCursorMetrics.artworkRotation
) -> NSBezierPath {
  let artwork = computerUsePointerArtwork(size: rect.size, rotation: rotation)
  let bounds = artwork.cgPath.boundingBoxOfPath
  var placement = CGAffineTransform(
    translationX: rect.midX - bounds.midX,
    y: rect.midY - bounds.midY
  )
  return NSBezierPath(cgPath: artwork.cgPath.copy(using: &placement) ?? artwork.cgPath)
}

/*
 The procedural cursor proportions and general motion approach above and below are
 adapted from open-codex-computer-use (https://github.com/iFurySt/open-codex-computer-use),
 commit 460d281c0597ab83e703d0215affd9d89978c506.

 MIT License

 Copyright (c) 2026 Leo

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
*/
final class ComputerUseCursorView: NSView {
  var rotation: CGFloat = 0
  var rotationAroundCenter = false
  var bodyOffset: CGVector = .zero
  var clickProgress: CGFloat = 0
  /// Per-agent accent. The pointer body and glow derive from this color so
  /// concurrent sessions are visually distinguishable at a glance.
  var tint: NSColor = .black {
    didSet { needsDisplay = true }
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.clear(bounds)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let fogCenter = CGPoint(
      x: bounds.midX + bodyOffset.dx * 0.15,
      y: bounds.midY + bodyOffset.dy * 0.15
    )
    let radius: CGFloat = 28 + clickProgress * 1.0
    // Soften the accent toward the original neutral fog so the glow reads
    // as a subtle halo in the agent's color rather than a saturated blob.
    let fog =
      tint.blended(withFraction: 0.55, of: NSColor(calibratedWhite: 0.42, alpha: 1))
      ?? tint
    let colors =
      [
        fog.withAlphaComponent(0.32 + clickProgress * 0.02).cgColor,
        fog.withAlphaComponent(0.20 + clickProgress * 0.015).cgColor,
        fog.withAlphaComponent(0.07).cgColor,
        NSColor.clear.cgColor,
      ] as CFArray
    if let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors,
      locations: [0, 0.50, 0.82, 1]
    ) {
      context.drawRadialGradient(
        gradient,
        startCenter: fogCenter,
        startRadius: 0,
        endCenter: fogCenter,
        endRadius: radius,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
      )
    }

    let pointerTip = CGPoint(
      x: ComputerUseCursorMetrics.tipAnchor.x + bodyOffset.dx,
      y: ComputerUseCursorMetrics.tipAnchor.y + bodyOffset.dy
    )
    let path = computerUsePointerPath(
      tip: pointerTip,
      size: ComputerUseCursorMetrics.pointerSize
    )
    let rotationPivot =
      rotationAroundCenter
      ? CGPoint(x: path.bounds.midX, y: path.bounds.midY)
      : pointerTip

    context.saveGState()
    context.concatenate(
      computerUseTipPreservingRotation(
        tip: pointerTip,
        pivot: rotationPivot,
        angle: rotation
      )
    )
    context.translateBy(
      x: pointerTip.x,
      y: pointerTip.y
    )
    context.scaleBy(
      x: 1 - clickProgress * 0.04,
      y: 1 + clickProgress * 0.02
    )
    context.translateBy(
      x: -pointerTip.x,
      y: -pointerTip.y
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 3.2 + clickProgress * 1.4
    shadow.shadowOffset = CGSize(width: 0, height: -0.35)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.11)
    shadow.set()
    NSColor.black.withAlphaComponent(0.05).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    tint.withAlphaComponent(0.94).setFill()
    path.fill()
    NSColor(calibratedWhite: 0.90, alpha: 0.92).setStroke()
    path.lineWidth = 1.25
    path.lineJoinStyle = .round
    path.lineCapStyle = .round
    path.stroke()
    context.restoreGState()
  }

}
