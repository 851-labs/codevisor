import StreamMarkdown
import SwiftUI
import Testing
import UIKit

@testable import TranscriptSurface

@Suite("iOS send morph text")
@MainActor
struct UserSendMorphTextTests {
  @Test(
    "The landed proxy paints the same text as the selectable transcript",
    arguments: [
      "A short message",
      "Please keep the carefully crafted send animation exactly as it is while fixing the words moving around.",
      "First line\n\nAnother paragraph with a longer line that wraps at the bubble edge.\n",
      "Check https://example.com/a/long/path and user_message_layout.swift with 👩🏽‍💻 and café.",
      "日本語のメッセージも改行位置が変わらないように確認します。Hello world!",
      "مرحبا بالعالم، هذه رسالة للتأكد من ثبات مواضع الكلمات عند الإرسال.",
    ],
    [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge]
  )
  func landingMatchesTranscript(text: String, contentSize: UIContentSizeCategory) throws {
    let traits = UITraitCollection {
      $0.preferredContentSizeCategory = contentSize
      $0.userInterfaceStyle = .light
      $0.layoutDirection = .leftToRight
      $0.displayScale = 3
    }
    var result: Result<Void, Error> = .success(())
    traits.performAsCurrent {
      result = Result { try checkLanding(text: text, traits: traits) }
    }
    try result.get()
  }

  private func checkLanding(text: String, traits: UITraitCollection) throws {
    let width: CGFloat = 263
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.preferredFont(forTextStyle: .body),
      .foregroundColor: UIColor.black,
    ]
    let host = UIHostingController(
      rootView: SelectableTextView(
        attributedText: NSAttributedString(string: text, attributes: attributes),
        fillsWidth: false
      )
      .environment(\.streamMarkdownTextLayoutWidth, width)
      .environment(\.locale, Locale(identifier: "en_US"))
      .environment(\.dynamicTypeSize, traits.preferredContentSizeCategory == .large ? .large : .accessibility5)
    )
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
    let parent = UIViewController()
    parent.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
    parent.traitOverrides.userInterfaceStyle = traits.userInterfaceStyle
    parent.traitOverrides.layoutDirection = traits.layoutDirection
    parent.traitOverrides.displayScale = traits.displayScale
    window.rootViewController = parent
    window.isHidden = false
    parent.addChild(host)
    parent.view.addSubview(host.view)
    host.didMove(toParent: parent)
    defer {
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
      window.isHidden = true
      window.rootViewController = nil
    }
    let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    host.view.frame = CGRect(origin: .zero, size: size)
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    let transcript = try #require(firstTextView(in: host.view))
    transcript.layoutIfNeeded()
    #expect(transcript.bounds.width > 0)
    #expect(transcript.bounds.height > 0)

    let proxy = UserSendMorphView(text: text, bubbleColor: .clear, textColor: .black)
    parent.view.addSubview(proxy)
    defer { proxy.removeFromSuperview() }
    // Exercise UIKit's animated resize too: UITextView can defer its
    // text-container width even after its model frame reaches the target.
    // Drive the animator directly so no elapsed-time wait controls layout.
    proxy.frame = CGRect(x: 0, y: 600, width: 364, height: 120)
    proxy.layoutIfNeeded()
    let target = CGRect(
      x: 0, y: 0,
      width: transcript.bounds.width + 24,
      height: transcript.bounds.height + 16
    )
    let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
      proxy.frame = target
      proxy.layoutIfNeeded()
    }
    animator.startAnimation()
    animator.pauseAnimation()
    animator.fractionComplete = 1
    defer { animator.stopAnimation(true) }
    let proxyText = try #require(firstTextView(in: proxy))
    #expect(proxyText.textContainer.size.width == transcript.textContainer.size.width)

    let landedText = proxy.bounds.inset(by: UserSendMorphView.insets)
    let transcriptPixels = try pixels(in: transcript, rect: transcript.bounds)
    // Prove that the reference painted glyphs, rather than comparing two
    // empty text surfaces before UIKit has drawn either one.
    #expect(transcriptPixels.contains { $0 > 0 && $0 < 255 })
    #expect(try pixels(in: proxy, rect: landedText) == transcriptPixels)
  }

  private func firstTextView(in view: UIView) -> UITextView? {
    if let text = view as? UITextView { return text }
    return view.subviews.lazy.compactMap { firstTextView(in: $0) }.first
  }

  private func pixels(in view: UIView, rect: CGRect) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.opaque = true
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: rect.size))
      context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
      view.layer.render(in: context.cgContext)
    }
    let cgImage = try #require(image.cgImage)
    let data = try #require(cgImage.dataProvider?.data) as Data
    let rowBytes = cgImage.width * cgImage.bitsPerPixel / 8
    var pixels = Data()
    for row in 0..<cgImage.height {
      let start = row * cgImage.bytesPerRow
      // Ignore backing-store alignment bytes outside the rendered image.
      pixels.append(data[start..<(start + rowBytes)])
    }
    return pixels
  }
}
