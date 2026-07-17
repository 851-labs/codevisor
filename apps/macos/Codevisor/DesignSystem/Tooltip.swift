import AppKit
import SwiftUI

extension View {
    /// A fast, app-rendered tooltip for compact controls and truncated content.
    ///
    /// The tooltip is deliberately visual-only. Callers still provide a concise
    /// accessibility label for icon-only controls so VoiceOver never depends on
    /// hover. Pass an accessibility hint only when the tooltip communicates
    /// additional behavior that isn't already covered by the control's label.
    func tooltip(_ text: String, accessibilityHint: String? = nil) -> some View {
        modifier(TooltipModifier(text: text, accessibilityHint: accessibilityHint))
    }
}

@MainActor
private struct TooltipModifier: ViewModifier {
    private static let presentationDelay = Duration.milliseconds(350)

    let text: String
    let accessibilityHint: String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isHovered = false
    @State private var isPresented = false
    @State private var presentationTask: Task<Void, Never>?

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func body(content: Content) -> some View {
        Group {
            if hasText, let accessibilityHint, !accessibilityHint.isEmpty {
                tooltipPresentation(content)
                    .accessibilityHint(accessibilityHint)
            } else if hasText {
                tooltipPresentation(content)
            } else {
                content
            }
        }
    }

    private func tooltipPresentation(_ content: Content) -> some View {
        content
            // AppKit-backed geometric tracking is reliable over transparent
            // SwiftUI labels and toolbar controls on macOS 26.
            .hoverTracking($isHovered)
            .onChange(of: isHovered) { _, hovering in
                hovering ? schedulePresentation() : dismiss()
            }
            .onChange(of: text) { _, _ in
                guard hasText else {
                    dismiss()
                    return
                }
                if isHovered { schedulePresentation() }
            }
            .onDisappear {
                presentationTask?.cancel()
            }
            .background {
                TooltipPresentationAnchor(
                    text: text,
                    isPresented: isPresented,
                    colorScheme: colorScheme,
                    contrast: contrast,
                    dynamicTypeSize: dynamicTypeSize,
                    layoutDirection: layoutDirection,
                    reduceTransparency: reduceTransparency
                )
            }
    }

    private func schedulePresentation() {
        presentationTask?.cancel()
        presentationTask = Task { @MainActor in
            try? await Task.sleep(for: Self.presentationDelay)
            guard !Task.isCancelled, isHovered, hasText else { return }
            setPresented(true)
        }
    }

    private func dismiss() {
        presentationTask?.cancel()
        presentationTask = nil
        setPresented(false)
    }

    private func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
    }
}

/// Hosts the tooltip in a nonactivating AppKit panel so it can escape SwiftUI
/// clipping regions without behaving like an interactive popover. The panel
/// ignores mouse events, which keeps the control beneath the pointer clickable
/// while the tooltip is visible.
private struct TooltipPresentationAnchor: NSViewRepresentable {
    let text: String
    let isPresented: Bool
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let dynamicTypeSize: DynamicTypeSize
    let layoutDirection: LayoutDirection
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> TooltipAnchorView {
        TooltipAnchorView()
    }

    func updateNSView(_ view: TooltipAnchorView, context: Context) {
        view.update(
            content: TooltipPanelContent(
                text: text,
                colorScheme: colorScheme,
                contrast: contrast,
                dynamicTypeSize: dynamicTypeSize,
                layoutDirection: layoutDirection,
                reduceTransparency: reduceTransparency
            ),
            isPresented: isPresented
        )
    }

    static func dismantleNSView(_ view: TooltipAnchorView, coordinator: Void) {
        view.dismiss()
    }
}

private final class TooltipAnchorView: NSView {
    fileprivate static let contentInset: CGFloat = 12
    private static let gap: CGFloat = 4
    private static let screenInset: CGFloat = 6

    private var content = TooltipPanelContent(
        text: "",
        colorScheme: .light,
        contrast: .standard,
        dynamicTypeSize: .medium,
        layoutDirection: .leftToRight,
        reduceTransparency: false
    )
    private var wantsPresentation = false
    private var tooltipPanel: TooltipPanel?
    private var hostingView: NSHostingView<TooltipPanelContent>?

    func update(content: TooltipPanelContent, isPresented: Bool) {
        self.content = content
        wantsPresentation = isPresented
        updatePresentation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePresentation()
    }

    override func layout() {
        super.layout()
        guard wantsPresentation else { return }
        positionPanel()
    }

    func dismiss() {
        if let tooltipPanel, let parent = tooltipPanel.parent {
            parent.removeChildWindow(tooltipPanel)
        }
        tooltipPanel?.orderOut(nil)
        tooltipPanel = nil
        hostingView = nil
    }

    private func updatePresentation() {
        guard wantsPresentation, let window, !bounds.isEmpty else {
            dismiss()
            return
        }

        let panel: TooltipPanel

        if let existingPanel = tooltipPanel, let hostingView {
            panel = existingPanel
            hostingView.rootView = content
        } else {
            panel = TooltipPanel()
            let hostingView = NSHostingView(rootView: content)
            panel.contentView = hostingView
            tooltipPanel = panel
            self.hostingView = hostingView
        }

        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        panel.setContentSize(hostingView.fittingSize)

        if panel.parent !== window {
            if let previousParent = panel.parent {
                previousParent.removeChildWindow(panel)
            }
            window.addChildWindow(panel, ordered: .above)
        }

        positionPanel()
        panel.orderFront(nil)
    }

    private func positionPanel() {
        guard
            let window,
            let panel = tooltipPanel,
            let screen = window.screen ?? NSScreen.main
        else { return }

        let anchorInWindow = convert(bounds, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame.insetBy(
            dx: Self.screenInset,
            dy: Self.screenInset
        )

        let minimumX = visibleFrame.minX
        let maximumX = visibleFrame.maxX - panelSize.width
        let centeredX = anchorOnScreen.midX - (panelSize.width / 2)
        let x = min(max(centeredX, minimumX), maximumX)

        let belowY = anchorOnScreen.minY
            - panelSize.height
            + Self.contentInset
            - Self.gap
        let aboveY = anchorOnScreen.maxY
            - Self.contentInset
            + Self.gap
        let preferredY = belowY >= visibleFrame.minY ? belowY : aboveY
        let maximumY = visibleFrame.maxY - panelSize.height
        let y = min(max(preferredY, visibleFrame.minY), maximumY)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class TooltipPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = true
        ignoresMouseEvents = true
        setAccessibilityElement(false)
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TooltipPanelContent: View {
    let text: String
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let dynamicTypeSize: DynamicTypeSize
    let layoutDirection: LayoutDirection
    let reduceTransparency: Bool

    var body: some View {
        TooltipBubble(
            text: text,
            contrast: contrast,
            reduceTransparency: reduceTransparency
        )
            .padding(TooltipAnchorView.contentInset)
            .preferredColorScheme(colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.layoutDirection, layoutDirection)
    }
}

private struct TooltipBubble: View {
    let text: String
    let contrast: ColorSchemeContrast
    let reduceTransparency: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color(nsColor: .labelColor))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: 320, alignment: .leading)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
