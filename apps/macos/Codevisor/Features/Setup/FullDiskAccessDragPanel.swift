import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class FullDiskAccessDragGuide {
  enum Pointer {
    case none, left, right, up
  }

  var pointer = Pointer.none
}

@MainActor
final class FullDiskAccessDragPanel {
  static let shared = FullDiskAccessDragPanel()

  private static let systemSettingsBundleId = "com.apple.systempreferences"
  private static let gap: CGFloat = 12
  private static let arrowSpan: CGFloat = 36

  private let guide = FullDiskAccessDragGuide()
  private var panel: NSPanel?
  private var cardSize = CGSize.zero
  private var placement: Task<Void, Never>?

  func show() {
    let panel = panel ?? makePanel()
    self.panel = panel
    placement?.cancel()
    placement = Task { [weak self] in
      for _ in 0..<40 {
        if let frame = Self.systemSettingsFrame() {
          self?.present(panel, beside: frame)
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
        if Task.isCancelled { return }
      }
      self?.presentFallback(panel)
    }
  }

  func close() {
    placement?.cancel()
    placement = nil
    panel?.orderOut(nil)
    panel = nil
  }

  private func makePanel() -> NSPanel {
    guide.pointer = .none
    let hosting = NSHostingView(rootView: FullDiskAccessDragPanelContent(guide: guide))
    cardSize = hosting.fittingSize
    let panel = NSPanel(
      contentRect: CGRect(origin: .zero, size: cardSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = hosting
    return panel
  }

  private func present(_ panel: NSPanel, beside settings: CGRect) {
    guard self.panel === panel else { return }
    let visible =
      (NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main)?.visibleFrame
      ?? settings
    let wide = CGSize(width: cardSize.width + Self.arrowSpan, height: cardSize.height)
    let tall = CGSize(width: cardSize.width, height: cardSize.height + Self.arrowSpan)
    let left = CGRect(
      origin: CGPoint(x: settings.minX - wide.width - Self.gap, y: settings.midY - wide.height / 2), size: wide)
    let right = CGRect(
      origin: CGPoint(x: settings.maxX + Self.gap, y: settings.midY - wide.height / 2), size: wide)
    let below = CGRect(
      origin: CGPoint(x: settings.midX - tall.width / 2, y: settings.minY - tall.height - Self.gap), size: tall)
    if visible.contains(left) {
      place(panel, in: left, pointer: .right)
    } else if visible.contains(right) {
      place(panel, in: right, pointer: .left)
    } else if visible.contains(below) {
      place(panel, in: below, pointer: .up)
    } else {
      let inside = CGPoint(x: settings.minX + Self.gap, y: settings.minY + Self.gap)
      place(panel, in: CGRect(origin: inside, size: cardSize), pointer: .none)
    }
  }

  private func presentFallback(_ panel: NSPanel) {
    guard self.panel === panel else { return }
    let visible = NSScreen.main?.visibleFrame ?? .zero
    let origin = CGPoint(x: visible.midX - cardSize.width / 2, y: visible.minY + Self.gap * 2)
    place(panel, in: CGRect(origin: origin, size: cardSize), pointer: .none)
  }

  private func place(_ panel: NSPanel, in frame: CGRect, pointer: FullDiskAccessDragGuide.Pointer) {
    guide.pointer = pointer
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
  }

  private static func systemSettingsFrame() -> CGRect? {
    guard
      let pid = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == systemSettingsBundleId })?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    let frames = windows.compactMap { window -> CGRect? in
      guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
        (window[kCGWindowLayer as String] as? Int) == 0,
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        rect.width > 300, rect.height > 200
      else { return nil }
      return rect
    }
    guard let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
  }
}

private struct FullDiskAccessDragPanelContent: View {
  let guide: FullDiskAccessDragGuide

  var body: some View {
    switch guide.pointer {
    case .none:
      card
    case .right:
      HStack(spacing: 0) {
        card
        PointerArrow(symbol: "arrow.right", axis: .horizontal, distance: 4)
      }
    case .left:
      HStack(spacing: 0) {
        PointerArrow(symbol: "arrow.left", axis: .horizontal, distance: -4)
        card
      }
    case .up:
      VStack(spacing: 0) {
        PointerArrow(symbol: "arrow.up", axis: .vertical, distance: -4)
        card
      }
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Give Codevisor Full Disk Access")
        .font(.headline)

      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          step(1, "Drag this into the list")
          AppDragChip(large: true)
            .padding(.leading, 30)
        }
        step(2, "Confirm with Touch ID or your password")
      }

      Divider()

      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Waiting for access…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(22)
    .frame(width: 320, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1))
    )
    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    .padding(12)
  }

  private func step(_ number: Int, _ title: String) -> some View {
    HStack(spacing: 10) {
      Text("\(number)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.accentColor.opacity(0.15)))
        .accessibilityHidden(true)
      Text(title)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct PointerArrow: View {
  let symbol: String
  let axis: Axis
  let distance: CGFloat

  @State private var nudged = false

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 22, weight: .bold))
      .foregroundStyle(.tint)
      .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
      .frame(width: axis == .horizontal ? 36 : nil, height: axis == .vertical ? 36 : nil)
      .offset(
        x: axis == .horizontal && nudged ? distance : 0,
        y: axis == .vertical && nudged ? distance : 0
      )
      .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: nudged)
      .onAppear { nudged = true }
      .accessibilityHidden(true)
  }
}
