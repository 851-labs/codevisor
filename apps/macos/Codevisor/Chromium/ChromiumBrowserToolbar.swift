import CodevisorUI
import SwiftUI

struct ChromiumBrowserNavigationControls: ToolbarContent {
  @Bindable var model: ChromiumBrowserModel

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      ChromiumBrowserNavigationButtons(model: model)
    }
  }
}

struct ChromiumBrowserNavigationButtons: View {
  @Bindable var model: ChromiumBrowserModel

  var body: some View {
    ControlGroup {
      Button("Back", systemImage: "chevron.left") { model.webView?.goBack() }
        .disabled(!model.canGoBack)
        .help("Back")
      Button("Forward", systemImage: "chevron.right") { model.webView?.goForward() }
        .disabled(!model.canGoForward)
        .help("Forward")
    }
    .controlGroupStyle(.navigation)
  }
}

/// Window controls share the pane model without owning its browser lifetime.
struct ChromiumBrowserToolbar: NSViewRepresentable {
  let model: ChromiumBrowserModel

  // Keep the composite toolbar inside one native view. Otherwise SwiftUI's
  // toolbar adaptation promotes the first button's action and accessibility
  // metadata to the other controls, leaving the address editor inert.
  func makeNSView(context: Context) -> ChromiumToolbarHost {
    let view = ChromiumToolbarHost(rootView: ChromiumBrowserToolbarContent(model: model))
    view.focusAddress = { [weak model] in model?.focusAddress() }
    view.sizingOptions = [.intrinsicContentSize]
    return view
  }

  func updateNSView(_ nsView: ChromiumToolbarHost, context: Context) {
    nsView.focusAddress = { [weak model] in model?.focusAddress() }
    nsView.rootView = ChromiumBrowserToolbarContent(model: model)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: ChromiumToolbarHost, context: Context
  )
    -> CGSize?
  {
    CGSize(width: min(850, max(280, proposal.width ?? 600)), height: 32)
  }
}

struct ChromiumBrowserToolbarContent: View {
  @Bindable var model: ChromiumBrowserModel
  @State private var address = ""
  @State private var editing = false
  @State private var focusRequest = 0

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        HStack(spacing: 0) {
          BrowserAddressEditor(
            text: $address, editing: $editing, focusRequest: focusRequest,
            fullAddress: model.url?.absoluteString ?? "", suggestions: model.suggestions,
            submit: { value in
              model.submitAddress(value)
              editing = false
              model.webView?.focusPage()
            },
            cancel: {
              editing = false
              updateAddress()
              model.webView?.focusPage()
            }
          )
          .padding(.leading, 14)
          browserButton(model.isLoading ? "Stop" : "Reload", symbol: model.isLoading ? "xmark" : "arrow.clockwise") {
            if model.isLoading { model.stop() } else { model.reload() }
          }
        }
        .frame(maxWidth: 720)
        .glassEffect(.regular.interactive(), in: .capsule)
        browserButton("Responsive viewport", symbol: "iphone.and.ipad") {
          Task {
            if model.viewport == nil {
              try? await model.setViewport(ChromiumViewport().parameters)
            } else {
              try? await model.resetViewport()
            }
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 280, idealWidth: 600, maxWidth: 850)
    .onAppear { updateAddress() }
    .onChange(of: model.url) { _, _ in if !editing { updateAddress() } }
    .onChange(of: editing) { _, focused in
      if !focused { model.suggestions.dismiss(); updateAddress() }
    }
    .onDisappear { model.suggestions.dismiss() }
    .onChange(of: model.addressFocusRequest) { _, _ in beginEditing() }
  }
  private func beginEditing() {
    if !editing { address = model.url?.absoluteString ?? "" }
    editing = true
    model.suggestions.dismiss()
    focusRequest += 1
  }

  private func updateAddress() { address = model.url.map(BrowserLocation.display) ?? "" }
  private func browserButton(
    _ title: String, symbol: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 34, height: 32) }
      .buttonStyle(.plain)
      .help(title)
      .accessibilityLabel(title)
  }
}
