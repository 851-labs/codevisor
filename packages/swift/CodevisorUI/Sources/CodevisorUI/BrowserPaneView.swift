import SwiftUI
import WebKit

public struct BrowserPaneView: View {
  @Bindable private var model: BrowserPaneModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  @ScaledMetric(relativeTo: .body) private var expandedHeight: CGFloat = 50
  @ScaledMetric(relativeTo: .subheadline) private var compactHeight: CGFloat = 34
  @State private var address = ""
  @State private var selection: TextSelection?
  @State private var isCollapsed = false
  /// The safe area over the page, measured in SwiftUI (see BrowserWebView).
  @State private var pageSafeArea = EdgeInsets()
  /// The page's width; sizes the address field when it sits in the top bar.
  @State private var pageWidth: CGFloat = 0
  /// Editing in the top bar's field, which keeps its own focus state:
  /// SwiftUI focus doesn't cross into content hosted in the toolbar.
  @State private var navigationAddressEditing = false
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
      .onDisappear {
        model.setVisible(false); model.suggestions.dismiss()
      }
      .onChange(of: model.url) { _, url in
        if !isEditingAddress { address = url?.absoluteString ?? "" }
        isCollapsed = false
      }
      .onChange(of: addressFocused) { _, focused in
        isCollapsed = false
        if focused {
          address = model.url?.absoluteString ?? address
          selection = TextSelection(range: address.startIndex..<address.endIndex)
        } else {
          model.suggestions.dismiss()
        }
      }
      .onChange(of: address) { _, value in
        if isEditingAddress { model.suggestions.update(value) }
      }
      .onChange(of: navigationAddressEditing) { _, editing in
        if !editing { model.suggestions.dismiss() }
      }
      .onChange(of: model.errorMessage) { _, error in
        if error != nil { isCollapsed = false }
      }
      .background {
        Button("Focus browser address") { editAddress() }
          .keyboardShortcut("l", modifiers: .command)
          .hidden()
      }
  }

  @ViewBuilder private var surface: some View {
    #if os(iOS)
      page
        .ignoresSafeArea(.container, edges: .vertical)
        .onGeometryChange(for: EdgeInsets.self) {
          $0.safeAreaInsets
        } action: {
          pageSafeArea = $0
        }
        // The model picks mobile or desktop sites by this width.
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          model.viewportWidth = $0
          pageWidth = $0
        }
        .overlay(alignment: .bottom) {
          if !usesNavigationBar {
            VStack(spacing: 8) {
              if addressFocused { suggestionList }
              toolbar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
          }
        }
        // In the top bar, suggestions drop down beneath the address field.
        .overlay(alignment: .top) {
          if usesNavigationBar, navigationAddressEditing {
            suggestionList
              .frame(maxWidth: Self.navigationAddressWidth)
              .padding(.horizontal, 12)
              .padding(.top, 8)
          }
        }
        .toolbar {
          if usesNavigationBar { navigationBarItems }
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
            // In the top bar the page keeps its whole height; the bottom
            // toolbar otherwise floats over it.
            bottomInset: usesNavigationBar ? 0 : (compact ? compactHeight + 10 : toolbarHeight) + 16,
            minimumBottomInset: usesNavigationBar ? 0 : compactHeight + 26,
            maximumBottomInset: usesNavigationBar ? 0 : max(compactHeight + 26, toolbarHeight + 16),
            safeArea: pageSafeArea
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
      isCollapsed && !keepExpanded && !usesNavigationBar
    #else
      false
    #endif
  }

  private var keepExpanded: Bool {
    addressFocused || voiceOverEnabled || dynamicTypeSize.isAccessibilitySize || model.errorMessage != nil
  }

  private var controlHeight: CGFloat {
    #if os(iOS)
      usesNavigationBar ? 38 : expandedHeight
    #else
      34
    #endif
  }

  /// Regular width (iPad) puts the controls in the top bar, as Safari and
  /// the macOS pane do; compact width keeps the floating bottom toolbar.
  /// Accessibility text sizes keep the bottom toolbar, which can wrap.
  private var usesNavigationBar: Bool {
    #if os(iOS)
      horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    #else
      false
    #endif
  }

  static let navigationAddressWidth: CGFloat = 560

  @ViewBuilder private var suggestionList: some View {
    if !model.suggestions.items.isEmpty {
      BrowserSuggestionList(suggestions: model.suggestions) { item in
        model.suggestions.dismiss()
        address = item.value
        submitAddress()
      }
      .frame(maxHeight: 320)
      .background(.regularMaterial, in: .rect(cornerRadius: 20))
    }
  }

  #if os(iOS)
    /// Back and forward beside the sidebar button; the address field in
    /// the middle of the bar, where the title would be.
    @ToolbarContentBuilder private var navigationBarItems: some ToolbarContent {
      ToolbarItemGroup(placement: .topBarLeading) {
        Button("Back", systemImage: "chevron.left") { model.webView?.goBack() }
          .disabled(!model.canGoBack)
        if model.canGoForward {
          Button("Forward", systemImage: "chevron.right") { model.webView?.goForward() }
        }
      }
      ToolbarItem(placement: .principal) {
        // The bar sizes its middle item to fit, so give the field its width
        // outright: as wide as Safari's, leaving room for the bar's buttons
        // on either side in a narrower window.
        NavigationAddressField(
          model: model, address: $address, isEditing: $navigationAddressEditing, onSubmit: submitAddress
        )
        .frame(width: max(200, min(Self.navigationAddressWidth, pageWidth - 260)))
      }
      .sharedBackgroundVisibility(.hidden)
    }
  #endif

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
          .onKeyPress(.downArrow) {
            model.suggestions.moveSelection(1); return .handled
          }
          .onKeyPress(.upArrow) {
            model.suggestions.moveSelection(-1); return .handled
          }
          .onKeyPress(.escape) {
            cancelEditing(); return .handled
          }
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

  private var isEditingAddress: Bool { addressFocused || navigationAddressEditing }

  private func editAddress() {
    isCollapsed = false
    if usesNavigationBar { navigationAddressEditing = true } else { addressFocused = true }
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
    navigationAddressEditing = false
    address = model.url?.absoluteString ?? address
  }

  private func submitAddress() {
    model.submitAddress(model.suggestions.selected?.value ?? address)
    model.suggestions.dismiss()
    addressFocused = false
    navigationAddressEditing = false
    isCollapsed = false
  }
}

#if os(iOS)
  /// The address field in the iPad top bar, as Safari's: the short address
  /// centered until tapped, then the full URL, selected, for editing.
  /// SwiftUI focus state doesn't track a field hosted in the toolbar, so
  /// editing follows the field's own begin/end callbacks instead.
  private struct NavigationAddressField: View {
    @Bindable var model: BrowserPaneModel
    @Binding var address: String
    @Binding var isEditing: Bool
    let onSubmit: () -> Void
    @FocusState private var focused: Bool
    @State private var editing = false

    var body: some View {
      HStack(spacing: 0) {
        ZStack {
          Text(model.url.map(BrowserAddress.display) ?? "Search or enter website address")
            .font(.body.weight(.medium))
            .foregroundStyle(model.url == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(editing ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
          // Always the tap target; its text shows only while editing so
          // the short address reads through until then.
          TextField("Search or enter website address", text: $address, onEditingChanged: editingChanged)
            .textFieldStyle(.plain)
            .focused($focused)
            .foregroundStyle(editing ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
            .tint(editing ? nil : .clear)
            .onSubmit(onSubmit)
            .onKeyPress(.downArrow) {
              model.suggestions.moveSelection(1)
              return .handled
            }
            .onKeyPress(.upArrow) {
              model.suggestions.moveSelection(-1)
              return .handled
            }
            .onKeyPress(.escape) {
              endEditing()
              return .handled
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .accessibilityLabel("Browser address")
            .accessibilityValue(model.url?.absoluteString ?? address)
        }
        .padding(.leading, 16)
        .padding(.trailing, editing ? 16 : 4)
        if !editing {
          Button {
            if model.isLoading { model.stop() } else { model.reload() }
          } label: {
            Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(model.isLoading ? "Stop loading" : "Reload")
        }
      }
      .frame(height: 38)
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
      .glassEffect(.regular.interactive(), in: .capsule)
      .onChange(of: isEditing) { _, wanted in
        if wanted, !editing { focused = true }
        if !wanted, editing { endEditing() }
      }
    }

    private func editingChanged(_ began: Bool) {
      editing = began
      if isEditing != began { isEditing = began }
      guard began else { return }
      address = model.url?.absoluteString ?? address
      // Select the whole address once the new text is in the field, as
      // Safari does, so typing replaces it.
      DispatchQueue.main.async {
        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
      }
    }

    private func endEditing() {
      focused = false
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
  }
#endif

#if os(macOS)
  private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
  }
#endif
