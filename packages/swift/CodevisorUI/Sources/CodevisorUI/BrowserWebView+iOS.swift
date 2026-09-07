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
        maximumBottomInset: maximumBottomInset
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
        var obscured = safeAreaInsets
        obscured.bottom += bottomInset
        var minimum = safeAreaInsets
        minimum.bottom += minimumBottomInset
        var maximum = safeAreaInsets
        maximum.bottom += maximumBottomInset
        if webView.minimumViewportInset != minimum || webView.maximumViewportInset != maximum {
          webView.setMinimumViewportInset(minimum, maximumViewportInset: maximum)
        }
        if webView.obscuredContentInsets != obscured { webView.obscuredContentInsets = obscured }
        updateScrollInsets(obscured)
        if webView.scrollView.verticalScrollIndicatorInsets != obscured {
          webView.scrollView.verticalScrollIndicatorInsets = obscured
        }
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
