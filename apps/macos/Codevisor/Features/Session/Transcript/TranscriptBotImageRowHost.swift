import AppKit
import CodevisorUI
import StreamMarkdown
import SwiftUI

@MainActor
final class TranscriptBotImageRowHost: TranscriptMountedRowHost {
  private static let maximumSize = CGSize(width: 320, height: 280)
  private static let placeholderAspectRatio: CGFloat = 16 / 9
  private let picture = CALayer()
  private let placeholder = TranscriptBubbleBackgroundView()
  private let placeholderIcon = NSImageView()
  private var source = ""
  private var alt = ""
  private var image: MarkdownImage?
  private var loadTask: Task<Void, Never>?
  private var linkAction: MarkdownLinkAction?
  private var reportedHeight: CGFloat?

  override var isFlipped: Bool { true }
  override var isPresentationReady: Bool { true }
  override var needsRunwayPreparation: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    installVerticalClipMask()
    configurePicture()
    configurePlaceholder()
    addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openImage)))
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setContent(
    source: String, alt: String, linkAction: MarkdownLinkAction?, imageLoader: MarkdownImageLoader,
    knownHeight: CGFloat?
  ) {
    self.linkAction = linkAction
    self.alt = alt
    setAccessibilityLabel(alt.isEmpty ? "Image" : alt)
    reportedHeight = knownHeight
    guard source != self.source else {
      layoutPicture()
      return
    }

    self.source = source
    show(nil)
    load(source, using: imageLoader)
  }

  override func layout() {
    super.layout()
    layoutPicture()
  }

  override func requestContentMeasurement(forceReport: Bool = true) {
    if forceReport { reportedHeight = nil }
    layoutPicture()
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    guard let url = URL(string: source), let items = linkAction?.files?.menu(url), !items.isEmpty else { return nil }

    return MarkdownLinkMenu.menu(for: items)
  }

  override func accessibilityPerformPress() -> Bool {
    openImage()
    return true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return pictureFrame.contains(local) ? self : nil
  }

  private var pictureFrame: CGRect {
    CGRect(origin: .zero, size: pictureSize)
  }

  private var pictureSize: CGSize {
    boundedAttachmentPreviewSize(
      aspectRatio: aspectRatio, maximumSize: Self.maximumSize, fallbackAspectRatio: Self.placeholderAspectRatio)
  }

  private var aspectRatio: CGFloat? {
    guard let size = image?.image.size, size.width > 0, size.height > 0 else { return nil }
    return size.width / size.height
  }

  private func configurePicture() {
    picture.contentsGravity = .resizeAspect
    picture.cornerCurve = .continuous
    picture.masksToBounds = true
    layer?.addSublayer(picture)
  }

  private func configurePlaceholder() {
    placeholder.cornerRadius = UserBubbleBackground.cornerRadius(for: .large)
    placeholderIcon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    placeholderIcon.symbolConfiguration = .init(textStyle: .body)
    placeholderIcon.contentTintColor = .tertiaryLabelColor
    placeholderIcon.setAccessibilityHidden(true)
    addSubview(placeholder)
    placeholder.addSubview(placeholderIcon)
  }

  private func load(_ source: String, using loader: MarkdownImageLoader) {
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      let loaded = await loader.image(for: source)
      guard !Task.isCancelled, let self, self.source == source else { return }
      self.show(loaded)
    }
  }

  private func show(_ loaded: MarkdownImage?) {
    image = loaded
    picture.contents = loaded?.image
    picture.isHidden = loaded == nil
    placeholder.isHidden = loaded != nil
    layoutPicture()
  }

  private func layoutPicture() {
    let frame = pictureFrame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    picture.frame = frame
    picture.cornerRadius = UserBubbleBackground.cornerRadius(for: .large)
    CATransaction.commit()
    placeholder.frame = frame
    placeholderIcon.sizeToFit()
    placeholderIcon.frame.origin = CGPoint(
      x: floor((frame.width - placeholderIcon.frame.width) / 2),
      y: floor((frame.height - placeholderIcon.frame.height) / 2))
    report(ceil(frame.height))
  }

  private func report(_ height: CGFloat) {
    guard reportedHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }

    reportedHeight = height
    onHeightChange?(height)
  }

  @objc private func openImage() {
    guard let url = URL(string: source) else { return }

    _ = linkAction?.activate(url, isImage: true)
  }
}
