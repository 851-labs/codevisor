import SwiftUI
import WebKit

public struct BrowserPaneView: View {
  @Bindable private var model: BrowserPaneModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var expandedHeight: CGFloat = 50
  @ScaledMetric(relativeTo: .subheadline) private var compactHeight: CGFloat = 34
  @State private var address = ""
  @State private var selection: TextSelection?
  @State private var isCollapsed = false
  @FocusState private var addressFocused: Bool
  @Namespace private var glass

  public init(model: BrowserPaneModel) { self.model = model }

  public var body: some View {
    surface
      // The glass and WebKit's obscured viewport share one animation transaction.
      .animation(toolbarAnimation, value: compact)
      .animation(toolbarAnimation, value: addressFocused)
      .animation(toolbarAnimation, value: model.canGoForward)
      .onAppear {
        address = model.url?.absoluteString ?? "https://www.google.com/"
        model.setVisible(true)
      }
      .onDisappear { model.setVisible(false) }
      .onChange(of: model.url) { _, url in
        if !addressFocused { address = url?.absoluteString ?? "" }
        isCollapsed = false
      }
      .onChange(of: addressFocused) { _, focused in
        isCollapsed = false
        if focused {
          address = model.url?.absoluteString ?? address
          selection = TextSelection(range: address.startIndex..<address.endIndex)
        }
      }
      .onChange(of: model.errorMessage) { _, error in
        if error != nil { isCollapsed = false }
      }
      #if os(macOS)
        .background {
          Button("Focus browser address") { editAddress() }
          .keyboardShortcut("l", modifiers: .command)
          .hidden()
        }
      #endif
  }

  @ViewBuilder private var surface: some View {
    #if os(iOS)
      page
        .ignoresSafeArea(.container, edges: .vertical)
        .overlay(alignment: .bottom) {
          toolbar
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(model.pageAppearance.chromeColor)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbarColorScheme(model.pageAppearance.chromeScheme, for: .navigationBar)
    #else
      VStack(spacing: 0) {
        toolbar.padding(.horizontal, 12).padding(.vertical, 8)
          .background(model.pageAppearance.chromeColor)
          .environment(\.colorScheme, model.pageAppearance.chromeScheme)
        page
      }
    #endif
  }

  private var page: some View {
    ZStack {
      if let webView = model.webView {
        #if os(iOS)
          BrowserWebView(
            webView: webView, isCollapsed: $isCollapsed,
            keepExpanded: keepExpanded,
            isLoading: model.isLoading, onRefresh: model.reload,
            bottomInset: (compact ? compactHeight + 10 : toolbarHeight) + 16,
            minimumBottomInset: compactHeight + 26,
            maximumBottomInset: max(compactHeight + 26, toolbarHeight + 16)
          )
        #else
          BrowserWebView(webView: webView)
        #endif
      }
      if let error = model.errorMessage {
        ContentUnavailableView {
          Label("Page unavailable", systemImage: "network.slash")
        } description: {
          Text(error)
        } actions: {
          Button("Retry") { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
      } else if model.webView == nil {
        ProgressView("Connecting to \(model.machineName)…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var compact: Bool {
    #if os(iOS)
      isCollapsed && !keepExpanded
    #else
      false
    #endif
  }

  private var keepExpanded: Bool {
    addressFocused || voiceOverEnabled || dynamicTypeSize.isAccessibilitySize || model.errorMessage != nil
  }

  private var controlHeight: CGFloat {
    #if os(iOS)
      expandedHeight
    #else
      34
    #endif
  }

  private var toolbar: some View {
    GlassEffectContainer(spacing: 8) {
      toolbarLayout {
        if !compact && !addressFocused {
          navigationButtons
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("navigation", in: glass)
            .glassEffectTransition(.matchedGeometry)
        }
        addressBar
          .glassEffect(.regular.interactive(), in: .capsule)
          .glassEffectID("address", in: glass)
          .glassEffectTransition(.matchedGeometry)
          .padding(.vertical, compact ? 5 : 0)
        if addressFocused {
          Button("Cancel", systemImage: "xmark") { cancelEditing() }
            .labelStyle(.iconOnly)
            .frame(width: controlHeight, height: controlHeight)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("cancel", in: glass)
            .glassEffectTransition(.matchedGeometry)
        }
      }
      .buttonStyle(.plain)
      .font(.body.weight(.medium))
    }
    .frame(maxWidth: .infinity)
  }

  private var toolbarAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }

  private var toolbarLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 8))
  }

  private var toolbarHeight: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? controlHeight * 2 + 8 : controlHeight
  }

  private var navigationButtons: some View {
    HStack(spacing: 0) {
      navigationButton("Back", icon: "chevron.left", enabled: model.canGoBack) { model.webView?.goBack() }
      if model.canGoForward {
        navigationButton("Forward", icon: "chevron.right", enabled: true) { model.webView?.goForward() }
      }
    }
    .padding(.horizontal, model.canGoForward ? 3 : 0)
  }

  private func navigationButton(_ label: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Image(systemName: icon)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .frame(width: model.canGoForward ? controlHeight - 6 : controlHeight, height: controlHeight)
        .contentShape(Rectangle())
    }
    .disabled(!enabled)
    .accessibilityLabel(label)
    .help(label)
  }

  private var addressBar: some View {
    HStack(spacing: 0) {
      // Keep the label, editor, and glass in one persistent view. Replacing the
      // compact button with an HStack crossfades two different address surfaces.
      Button(action: activateAddress) {
        Text(displayAddress)
          .font(compact ? .subheadline.weight(.medium) : .body.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: compact ? nil : .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Browser address")
      .accessibilityValue(model.url?.absoluteString ?? address)
      .accessibilityHint(compact ? "Expand browser controls" : "Search or enter website address")
      .opacity(addressFocused ? 0 : 1)
      .accessibilityHidden(addressFocused)
      .animation(nil, value: addressFocused)
      .overlay {
        TextField("Search or enter website address", text: $address, selection: $selection)
          .textFieldStyle(.plain)
          .focused($addressFocused)
          .onSubmit { submitAddress() }
          .accessibilityLabel("Browser address")
          .opacity(addressFocused ? 1 : 0)
          .allowsHitTesting(addressFocused)
          .accessibilityHidden(!addressFocused)
          .animation(nil, value: addressFocused)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.webSearch)
            .submitLabel(.go)
          #endif
      }
      .padding(.leading, compact ? 24 : 16)
      .padding(.trailing, compact ? 24 : addressFocused ? 16 : 4)
      if !compact && !addressFocused {
        Button {
          if model.isLoading { model.stop() } else { model.reload() }
        } label: {
          Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            .frame(width: controlHeight, height: controlHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(model.isLoading ? "Stop loading" : "Reload")
        .help(model.isLoading ? "Stop loading" : "Reload")
      }
    }
    .font(.body)
    .frame(height: compact ? compactHeight : controlHeight)
    .overlay(alignment: .bottom) {
      if model.isLoading {
        GeometryReader { geometry in
          Capsule().fill(.tint)
            .frame(width: geometry.size.width * max(0.02, min(1, model.progress)))
        }
        .frame(height: 2)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
      }
    }
    .clipShape(Capsule())
    .contentShape(Rectangle())
  }

  private var displayAddress: String {
    model.url.map(BrowserAddress.display) ?? "Search or enter website address"
  }

  private func editAddress() {
    isCollapsed = false
    addressFocused = true
  }

  private func activateAddress() {
    if compact {
      isCollapsed = false
    } else {
      editAddress()
    }
  }

  private func cancelEditing() {
    addressFocused = false
    address = model.url?.absoluteString ?? address
  }

  private func submitAddress() {
    model.submitAddress(address)
    addressFocused = false
    isCollapsed = false
  }
}

#if os(macOS)
  private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
  }
#endif
