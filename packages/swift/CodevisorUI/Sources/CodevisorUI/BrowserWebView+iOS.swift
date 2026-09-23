#if os(iOS)
  import SwiftUI
  import WebKit

  struct BrowserWebView: View, Animatable {
    let webView: WKWebView
    @Binding var isCollapsed: Bool
    let keepExpanded: Bool
    let isLoading: Bool
    let onRefresh: () -> Void
    nonisolated var bottomInset: CGFloat
    let minimumBottomInset: CGFloat
    let maximumBottomInset: CGFloat
    /// The SwiftUI safe area over the page. SwiftUI doesn't forward safe
    /// area it adds itself (a split pane's share of the top bar and home
    /// indicator) to UIKit views, whose own insets then read zero.
    var safeArea = EdgeInsets()

    // SwiftUI interpolates this value on the same timeline as the glass. Passing
    // only the target to UIViewRepresentable makes fixed page controls jump.
    nonisolated var animatableData: CGFloat {
      get { bottomInset }
      set { bottomInset = newValue }
    }

    var body: some View {
      Representable(
        webView: webView, isCollapsed: $isCollapsed, keepExpanded: keepExpanded,
        isLoading: isLoading, onRefresh: onRefresh,
        bottomInset: bottomInset, minimumBottomInset: minimumBottomInset,
        maximumBottomInset: maximumBottomInset, safeArea: safeArea
      )
    }

    private struct Representable: UIViewRepresentable {
      let webView: WKWebView
      @Binding var isCollapsed: Bool
      let keepExpanded: Bool
      let isLoading: Bool
      let onRefresh: () -> Void
      let bottomInset: CGFloat
      let minimumBottomInset: CGFloat
      let maximumBottomInset: CGFloat
      let safeArea: EdgeInsets

      func makeCoordinator() -> Coordinator { Coordinator(isCollapsed: $isCollapsed, onRefresh: onRefresh) }

      func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView(webView: webView)
        context.coordinator.attach(webView.scrollView)
        return container
      }

      func updateUIView(_ uiView: ContainerView, context: Context) {
        context.coordinator.isCollapsed = $isCollapsed
        context.coordinator.keepExpanded = keepExpanded
        context.coordinator.onRefresh = onRefresh
        context.coordinator.state.setCollapsed(isCollapsed)
        context.coordinator.updateRefreshControl(isLoading: isLoading, background: webView.underPageBackgroundColor)
        uiView.bottomInset = bottomInset
        uiView.minimumBottomInset = minimumBottomInset
        uiView.maximumBottomInset = maximumBottomInset
        uiView.swiftUISafeArea = UIEdgeInsets(
          top: safeArea.top, left: safeArea.leading, bottom: safeArea.bottom, right: safeArea.trailing)
        uiView.updateViewport()
      }

      static func dismantleUIView(_ uiView: ContainerView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.detach()
      }
    }

    /// The document draws behind the browser UI, but its layout viewport excludes
    /// that UI. Scroll padding alone doesn't move fixed composers or CSS viewports.
    final class ContainerView: UIView {
      let webView: WKWebView
      var bottomInset: CGFloat = 0
      var minimumBottomInset: CGFloat = 0
      var maximumBottomInset: CGFloat = 0
      /// SwiftUI's safe area over this view; for the top and bottom, the
      /// larger of it and UIKit's own is what the page must clear.
      var swiftUISafeArea: UIEdgeInsets = .zero
      private let originalObscuredInsets: UIEdgeInsets
      private let originalMinimumInset: UIEdgeInsets
      private let originalMaximumInset: UIEdgeInsets
      private let originalContentInset: UIEdgeInsets
      private let originalIndicatorInsets: UIEdgeInsets
      private let originalAdjustment: UIScrollView.ContentInsetAdjustmentBehavior
      private var appliedContentInset: UIEdgeInsets

      init(webView: WKWebView) {
        self.webView = webView
        originalObscuredInsets = webView.obscuredContentInsets
        originalMinimumInset = webView.minimumViewportInset
        originalMaximumInset = webView.maximumViewportInset
        originalContentInset = webView.scrollView.contentInset
        appliedContentInset = originalContentInset
        originalIndicatorInsets = webView.scrollView.verticalScrollIndicatorInsets
        originalAdjustment = webView.scrollView.contentInsetAdjustmentBehavior
        super.init(frame: .zero)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(webView)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

      override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        updateViewport()
      }

      override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateViewport()
      }

      func updateViewport() {
        guard !bounds.isEmpty else { return }
        // Only the vertical edges come from SwiftUI (the top bar and home
        // indicator). Its leading inset counts the floating sidebar even
        // though this view already sits beside it, which would shift the
        // page right by the sidebar's width; UIKit's own is correct.
        let safe = UIEdgeInsets(
          top: max(safeAreaInsets.top, swiftUISafeArea.top),
          left: safeAreaInsets.left,
          bottom: max(safeAreaInsets.bottom, swiftUISafeArea.bottom),
          right: safeAreaInsets.right
        )
        var obscured = safe
        obscured.bottom += bottomInset
        var minimum = safe
        minimum.bottom += minimumBottomInset
        var maximum = safe
        maximum.bottom += maximumBottomInset
        // WebKit throws on insets it can't honor. SwiftUI's safe area (unlike
        // UIKit's) isn't clamped to this view, and it can arrive while the
        // view is being inserted at a transient size; skip until layout
        // gives it room, which calls back here.
        // WebKit checks against its own bounds, which trail this view's
        // until the next layout pass sets them.
        if Self.fits(minimum, maximum, in: webView.bounds.size),
          webView.minimumViewportInset != minimum || webView.maximumViewportInset != maximum
        {
          webView.setMinimumViewportInset(minimum, maximumViewportInset: maximum)
        }
        if webView.obscuredContentInsets != obscured { webView.obscuredContentInsets = obscured }
        updateScrollInsets(obscured)
        if webView.scrollView.verticalScrollIndicatorInsets != obscured {
          webView.scrollView.verticalScrollIndicatorInsets = obscured
        }
      }

      /// Non-negative, minimum within maximum, and the maximum leaving part
      /// of the view unobscured on each axis.
      static func fits(_ minimum: UIEdgeInsets, _ maximum: UIEdgeInsets, in size: CGSize) -> Bool {
        let edges = [
          minimum.top, minimum.left, minimum.bottom, minimum.right,
          maximum.top, maximum.left, maximum.bottom, maximum.right,
        ]
        guard edges.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        guard minimum.top <= maximum.top, minimum.left <= maximum.left,
          minimum.bottom <= maximum.bottom, minimum.right <= maximum.right
        else { return false }
        return maximum.top + maximum.bottom < size.height && maximum.left + maximum.right < size.width
      }

      private func updateScrollInsets(_ insets: UIEdgeInsets) {
        let scrollView = webView.scrollView
        guard appliedContentInset != insets else { return }
        let previousTop = scrollView.adjustedContentInset.top
        let wasAtTop = abs(scrollView.contentOffset.y + previousTop) < 1

        // Obscured insets position fixed/sticky elements and define WebKit's
        // initial offset, but don't change UIScrollView's resting scroll bounds.
        // Both must agree or scrolling back to the top hides document content.
        // UIKit owns the refresh control's additional inset. Apply only our
        // viewport delta so layout updates don't remove the active spinner.
        let current = scrollView.contentInset
        scrollView.contentInset = UIEdgeInsets(
          top: current.top + insets.top - appliedContentInset.top,
          left: current.left + insets.left - appliedContentInset.left,
          bottom: current.bottom + insets.bottom - appliedContentInset.bottom,
          right: current.right + insets.right - appliedContentInset.right
        )
        appliedContentInset = insets
        if wasAtTop, previousTop != scrollView.adjustedContentInset.top,
          !scrollView.isTracking, !scrollView.isDecelerating
        {
          scrollView.contentOffset.y = -scrollView.adjustedContentInset.top
        }
      }

      func detach() {
        webView.obscuredContentInsets = originalObscuredInsets
        webView.setMinimumViewportInset(originalMinimumInset, maximumViewportInset: originalMaximumInset)
        webView.scrollView.contentInset = originalContentInset
        webView.scrollView.verticalScrollIndicatorInsets = originalIndicatorInsets
        webView.scrollView.contentInsetAdjustmentBehavior = originalAdjustment
        webView.removeFromSuperview()
      }
    }

    @MainActor
    final class Coordinator: NSObject {
      var isCollapsed: Binding<Bool>
      var onRefresh: () -> Void
      var keepExpanded = false
      var state = BrowserToolbarScrollState()
      private var observation: NSKeyValueObservation?
      private weak var scrollView: UIScrollView?
      private let refreshControl = UIRefreshControl()
      private var originalRefreshControl: UIRefreshControl?
      private var originalAlwaysBounceVertical = false

      init(isCollapsed: Binding<Bool>, onRefresh: @escaping () -> Void) {
        self.isCollapsed = isCollapsed
        self.onRefresh = onRefresh
        super.init()
        refreshControl.tintColor = .secondaryLabel
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
      }

      func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        originalRefreshControl = scrollView.refreshControl
        originalAlwaysBounceVertical = scrollView.alwaysBounceVertical
        scrollView.refreshControl = refreshControl
        scrollView.alwaysBounceVertical = true
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
          Task { @MainActor [weak self] in self?.didScroll() }
        }
      }

      @objc private func refresh() {
        isCollapsed.wrappedValue = false
        onRefresh()
      }

      func updateRefreshControl(isLoading: Bool, background: UIColor) {
        refreshControl.overrideUserInterfaceStyle =
          BrowserPageAppearance(background: background, theme: nil).chromeScheme == .dark ? .dark : .light
        if !isLoading, refreshControl.isRefreshing { refreshControl.endRefreshing() }
      }

      private func didScroll() {
        guard let scrollView else { return }
        let inset = scrollView.adjustedContentInset
        let maximum = max(0, scrollView.contentSize.height + inset.top + inset.bottom - scrollView.bounds.height)
        state.update(
          offset: scrollView.contentOffset.y + inset.top,
          maximumOffset: maximum,
          isUserScrolling: scrollView.isDragging || scrollView.isDecelerating,
          keepExpanded: keepExpanded
        )
        if isCollapsed.wrappedValue != state.isCollapsed { isCollapsed.wrappedValue = state.isCollapsed }
      }

      func detach() {
        observation = nil
        refreshControl.endRefreshing()
        if scrollView?.refreshControl === refreshControl { scrollView?.refreshControl = originalRefreshControl }
        scrollView?.alwaysBounceVertical = originalAlwaysBounceVertical
        originalRefreshControl = nil
        scrollView = nil
        onRefresh = {}
      }
    }
  }
#endif
