import CoreGraphics
import QuartzCore

public struct TranscriptSendLanding: Equatable, Sendable {
  public var trailing: CGFloat
  public var top: CGFloat
  public var maxBubbleWidth: CGFloat

  public init(trailing: CGFloat, top: CGFloat, maxBubbleWidth: CGFloat) {
    self.trailing = trailing
    self.top = top
    self.maxBubbleWidth = maxBubbleWidth
  }
}

public enum TranscriptSendMorphGeometry {
  public static func startBubble(editorFrame: CGRect, textRect: CGRect) -> CGRect {
    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    let text = visibleText(editorFrame: editorFrame, textRect: textRect)
    return CGRect(
      x: editorFrame.minX - insets.horizontal,
      y: text.minY - insets.vertical,
      width: editorFrame.width + insets.horizontal * 2,
      height: text.height + insets.vertical * 2
    )
  }

  public static func predictedEnd(
    start: CGRect,
    editorFrame: CGRect,
    textRect: CGRect,
    lineHeight: CGFloat,
    landing: TranscriptSendLanding
  ) -> CGRect {
    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    let text = visibleText(editorFrame: editorFrame, textRect: textRect)
    let maxTextWidth = max(0, landing.maxBubbleWidth - insets.horizontal * 2)
    let isSingleLine = lineHeight > 0 && text.height < lineHeight * 1.5
    let textWidth = isSingleLine ? min(text.width, maxTextWidth) : maxTextWidth
    let width = textWidth + insets.horizontal * 2
    return CGRect(x: landing.trailing - width, y: landing.top, width: width, height: start.height)
  }

  private static func visibleText(editorFrame: CGRect, textRect: CGRect) -> CGRect {
    let visible = textRect.intersection(editorFrame)
    return visible.isNull || visible.isEmpty ? textRect : visible
  }
}

@MainActor
final class TranscriptSendMorph {
  private let pill: TranscriptSendPillView
  private(set) var end: CGRect
  private(set) var textMotion: [(key: String, animation: CAAnimation)] = []
  private var serial = 0
  private var settleSerial = 0
  private var riseKey: String?

  var riseBeginTime: CFTimeInterval? {
    guard let riseKey, let beginTime = pill.transcriptSendLayer?.animation(forKey: riseKey)?.beginTime,
      beginTime > 0
    else { return nil }
    return beginTime
  }

  init(pill: TranscriptSendPillView, from start: CGRect, to end: CGRect, onSettle: (() -> Void)? = nil) {
    self.pill = pill
    self.end = end
    move(from: start, to: end, onSettle: onSettle)
  }

  func retarget(to newEnd: CGRect, onSettle: (() -> Void)? = nil) {
    let old = end
    end = newEnd
    move(from: old, to: newEnd, onSettle: onSettle)
  }

  func carry(_ view: TranscriptSendPlatformView) {
    guard let layer = view.transcriptSendLayer else { return }
    for (key, animation) in textMotion {
      let running = pill.transcriptSendLayer?.animation(forKey: key) ?? animation
      if let copy = running.copy() as? CAAnimation { layer.add(copy, forKey: key) }
    }
  }

  private func move(from: CGRect, to: CGRect, onSettle: (() -> Void)?) {
    serial &+= 1
    let now: CFTimeInterval = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pill.setTranscriptSendFrame(to)
    for layer in pill.shapeLayers {
      layer.frame = CGRect(origin: .zero, size: to.size)
    }

    let slide = TranscriptSendMotion.bubbleSlide
    let rise = TranscriptSendMotion.bubble
    let x = TranscriptSendLayerAnimations.additiveSpring(
      keyPath: "transform.translation.x", offset: from.minX - to.minX, zero: CGFloat(0),
      spring: slide, beginTime: now)
    let y = TranscriptSendLayerAnimations.additiveSpring(
      keyPath: "transform.translation.y", offset: from.minY - to.minY, zero: CGFloat(0),
      spring: rise, beginTime: now)
    if let onSettle {
      settleSerial = serial
      let settles = serial
      y.delegate = TranscriptSendAnimationCompletion { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.settleSerial == settles else { return }
          onSettle()
        }
      }
    }
    let xKey = "codevisor.send-morph.x.\(serial)"
    let yKey = "codevisor.send-morph.y.\(serial)"
    if riseKey == nil { riseKey = yKey }
    pill.transcriptSendLayer?.add(x, forKey: xKey)
    pill.transcriptSendLayer?.add(y, forKey: yKey)
    textMotion.append((xKey, x))
    textMotion.append((yKey, y))

    let dw = from.width - to.width
    let dh = from.height - to.height
    let down = pill.backgroundYAxisPointsDown ? CGFloat(1) : -1
    let springs: [(String, CGFloat, TranscriptSpring)] = [
      ("bounds.size.width", dw, slide),
      ("position.x", dw / 2, slide),
      ("bounds.size.height", dh, slide),
      ("position.y", down * dh / 2, slide),
    ]
    for (keyPath, offset, spring) in springs where abs(offset) > 0.01 {
      for layer in pill.shapeLayers {
        layer.add(
          TranscriptSendLayerAnimations.additiveSpring(
            keyPath: keyPath, offset: offset, zero: CGFloat(0), spring: spring, beginTime: now),
          forKey: "codevisor.send-morph.\(keyPath).\(serial)")
      }
    }
    CATransaction.commit()
  }
}
